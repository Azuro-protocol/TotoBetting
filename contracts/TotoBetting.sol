// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.3;

import "./interface/IBetToken.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";

contract TotoBetting is OwnableUpgradeable {
    enum conditionState {
        CREATED,
        RESOLVED,
        CANCELED
    }

    struct Condition {
        uint128[2] totalNetBets;
        uint64[2] outcomes;
        uint128 scopeID;
        uint64 outcomeWin;
        uint64 timestamp;
        bytes32 ipfsHash;
        conditionState state;
    }

    address public token;
    IBetToken betToken;

    uint128 public DAOFee;
    uint128 public DAOReward;

    uint64 public expireTimer;

    uint128 public decimals;

    mapping(address => bool) public oracles;
    mapping(address => mapping(uint256 => uint256)) public oracleConditionIDs; // oracle -> oracleConditionID -> conditionID

    mapping(uint256 => Condition) public conditions;
    uint256 public lastConditionID;

    event BetTokenChanged(address indexed newBetToken);

    event OracleAdded(address indexed newOracle);
    event OracleRenounced(address indexed oracle);

    event ConditionCreated(
        uint256 indexed oracleCondID,
        uint256 indexed conditionID,
        uint64 timestamp
    );
    event ConditionResolved(
        uint256 indexed oracleCondID,
        uint256 indexed conditionID,
        uint64 outcomeWin
    );

    event NewBet(
        address indexed owner,
        uint256 indexed conditionID,
        uint256 indexed conditionOutcomeId,
        uint64 outcomeID,
        uint128 amount
    );
    event BetterWin(address indexed better, uint256 amount);

    modifier onlyOracle() {
        require(oracles[msg.sender], "Permission denied: Oracle only");
        _;
    }

    modifier outcomeIsCorrect(uint256 conditionID_, uint256 outcomeWin_) {
        require(
            isOutcomeCorrect(conditionID_, outcomeWin_),
            "Incorrect outcome"
        );
        _;
    }

    modifier betAllowed(uint256 conditionID_) {
        require(
            !conditionIsCanceled(conditionID_) &&
                block.timestamp < conditions[conditionID_].timestamp,
            "Bet is not allowed"
        );
        _;
    }

    function initialize(
        address token_,
        address betToken_,
        address oracle_,
        uint128 fee_
    ) public virtual initializer {
        require(token_ != address(0), "Wrong token");

        __Ownable_init();
        betToken = IBetToken(betToken_);
        oracles[oracle_] = true;
        DAOFee = fee_;
        expireTimer = 600;
        decimals = 10**9;
    }

    function changeBetToken(address betToken_) external onlyOwner {
        betToken = IBetToken(betToken_);
        emit BetTokenChanged(betToken_);
    }

    function addOracle(address oracle_) external onlyOwner {
        oracles[oracle_] = true;
        emit OracleAdded(oracle_);
    }

    function renounceOracle(address oracle_) external onlyOwner {
        oracles[oracle_] = false;
        emit OracleRenounced(oracle_);
    }

    function createCondition(
        uint256 oracleCondID_,
        uint64[2] memory outcomes_,
        uint128 scopeID_,
        uint64 timestamp_,
        bytes32 ipfsHash_
    ) external onlyOracle {
        require(timestamp_ > 0, "Timestamp can not be zero");
        require(
            timestamp_ + expireTimer < block.timestamp,
            "Condition is expired"
        );
        require(
            oracleConditionIDs[msg.sender][oracleCondID_] == 0,
            "Condition already exists"
        );

        lastConditionID++;
        oracleConditionIDs[msg.sender][oracleCondID_] = lastConditionID;

        Condition storage newCondition = conditions[lastConditionID];
        newCondition.outcomes = outcomes_;
        newCondition.scopeID = scopeID_;
        newCondition.timestamp = timestamp_;
        newCondition.ipfsHash = ipfsHash_;
        newCondition.state = conditionState.CREATED;

        emit ConditionCreated(oracleCondID_, lastConditionID, timestamp_);
    }

    function resolveCondition(uint256 oracleCondID_, uint64 outcomeWin_)
        external
        onlyOracle
    {
        uint256 conditionID = oracleConditionIDs[msg.sender][oracleCondID_];

        require(!conditionIsCanceled(conditionID), "Condition is canceled");
        require(
            isOutcomeCorrect(conditionID, outcomeWin_),
            "Incorrect outcome"
        );

        Condition storage condition = conditions[conditionID];

        require(condition.timestamp > 0, "Condition does not exist");
        require(
            block.timestamp >= condition.timestamp,
            "Condition has not started yet"
        );
        require(
            condition.state == conditionState.CREATED,
            "Condition already set"
        );
        uint128[2] memory fees = [
            (condition.totalNetBets[0] * DAOFee) / decimals,
            (condition.totalNetBets[1] * DAOFee) / decimals
        ];
        condition.totalNetBets[0] -= fees[0];
        condition.totalNetBets[1] -= fees[1];
        DAOReward += fees[0] + fees[1];

        condition.state = conditionState.RESOLVED;

        emit ConditionResolved(oracleCondID_, conditionID, outcomeWin_);
    }

    function conditionIsCanceled(uint256 conditionID_) internal returns (bool) {
        if (conditions[conditionID_].state == conditionState.CANCELED) {
            return true;
        }
        Condition storage condition = conditions[conditionID_];
        if (
            (block.timestamp + expireTimer >= condition.timestamp) &&
            (condition.totalNetBets[0] == 0 || condition.totalNetBets[1] == 0)
        ) {
            condition.state = conditionState.CANCELED;
            return true;
        }
        return false;
    }

    function isOutcomeCorrect(uint256 conditionID_, uint256 outcomeWin_)
        internal
        view
        returns (bool)
    {
        if (
            outcomeWin_ == conditions[conditionID_].outcomes[0] ||
            outcomeWin_ == conditions[conditionID_].outcomes[1]
        ) return true;
        return false;
    }

    function makeBet(
        uint256 conditionID_,
        uint64 outcomeWin_,
        uint128 amount_
    )
        external
        betAllowed(conditionID_)
        outcomeIsCorrect(conditionID_, outcomeWin_)
    {
        require(amount_ > 0, "Amount must not be zero");

        Condition storage condition = conditions[conditionID_];

        uint8 outcomeIndex = (outcomeWin_ == condition.outcomes[0] ? 0 : 1);

        condition.totalNetBets[outcomeIndex] += amount_;

        TransferHelper.safeTransferFrom(
            token,
            msg.sender,
            address(this),
            amount_
        );

        uint256 conditionOutcomeID = betToken.mint(
            msg.sender,
            lastConditionID,
            outcomeIndex,
            amount_
        );

        emit NewBet(
            msg.sender,
            conditionID_,
            conditionOutcomeID,
            outcomeWin_,
            amount_
        );
    }

    function withdrawPayout(uint256 conditionID_, uint64 outcomeWin_)
        external
        outcomeIsCorrect(conditionID_, outcomeWin_)
    {
        Condition memory condition = conditions[conditionID_];
        uint8 outcomeWinIndex = (outcomeWin_ == condition.outcomes[0] ? 0 : 1);
        uint256 conditionOutcomeID = betToken.getConditionOutcomeID(
            address(this),
            conditionID_,
            outcomeWinIndex
        );
        uint256 balance = betToken.balanceOfToken(
            msg.sender,
            conditionOutcomeID
        );

        require(
            condition.state == conditionState.RESOLVED == true ||
                conditionIsCanceled(conditionID_),
            "Condition is still on"
        );
        uint256 payout;
        if (condition.state == conditionState.RESOLVED) {
            if (conditionOutcomeID % 2 == outcomeWinIndex) {
                payout = 0;
            } else {
                payout =
                    ((condition.totalNetBets[0] + condition.totalNetBets[1]) *
                        balance) /
                    condition.totalNetBets[outcomeWinIndex];
            }
        } else {
            payout = balance;
        }

        betToken.burn(msg.sender, conditionOutcomeID, outcomeWinIndex, balance);
        TransferHelper.safeTransferFrom(
            token,
            address(this),
            msg.sender,
            payout
        );

        emit BetterWin(msg.sender, payout);
    }

    function claimDAOReward() external {
        require(DAOReward > 0, "No DAO reward");

        uint128 reward = DAOReward;
        DAOReward = 0;
        TransferHelper.safeTransfer(token, owner(), reward);
    }
}