// SPDX-License-Identifier: MIT

/**
 *  @authors: [@hbarcelos, @unknownunknown1]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity ^0.7.2;

import {IDisputeResolver, IArbitrator} from "@kleros/arbitrable-proxy-contracts/contracts/IDisputeResolver.sol";
import {CappedMath} from "@kleros/ethereum-libraries/contracts/CappedMath.sol";
import {IAMB} from "./dependencies/IAMB.sol";
import {IForeignArbitrationProxy, IHomeArbitrationProxy} from "./ArbitrationProxyInterfaces.sol";

/**
 * @title Arbitration proxy for Realitio on Ethereum side (A.K.A. the Foreign Chain).
 * @dev This contract is meant to be deployed to the Ethereum chains where Kleros is deployed.
 */
contract RealitioForeignArbitrationProxyWithAppeals is IForeignArbitrationProxy, IDisputeResolver {
    using CappedMath for uint256;

    /* Constants */
    uint256 public constant NUMBER_OF_CHOICES_FOR_ARBITRATOR = type(uint256).max - 1; // The number of choices for the arbitrator. Kleros is currently able to provide ruling values of up to 2^256 - 2.
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    /* Storage */

    enum Status {None, Requested, Created, Ruled, Failed}

    struct ArbitrationRequest {
        Status status; // Status of the arbitration.
        uint256 deposit; // The deposit paid by the requester at the time of the arbitration.
        uint256 disputeID; // The ID of the dispute in arbitrator contract.
        uint256 answer; // The answer given by the arbitrator shifted by -1 to match Realitio format.
        Round[] rounds; // Tracks each appeal round of a dispute.
    }

    struct DisputeDetails {
        uint256 arbitrationID; // The ID of the arbitration.
        address requester; // The address of the requester who managed to go through with the arbitration request.
    }

    // Round struct stores the contributions made to particular answers.
    struct Round {
        mapping(uint256 => uint256) paidFees; // Tracks the fees paid in this round in the form paidFees[answer].
        mapping(uint256 => bool) hasPaid; // True if the fees for this particular answer have been fully paid in the form hasPaid[answer].
        mapping(address => mapping(uint256 => uint256)) contributions; // Maps contributors to their contributions for each answer in the form contributions[address][answer].
        uint256 feeRewards; // Sum of reimbursable appeal fees available to the parties that made contributions to the answer that ultimately wins a dispute.
        uint256[] fundedAnswers; // Stores the answer choices that are fully funded.
    }

    address public governor = msg.sender; // The contract governor. TRUSTED.

    IArbitrator public immutable arbitrator; // The address of the arbitrator. TRUSTED.
    bytes public arbitratorExtraData; // The extra data used to raise a dispute in the arbitrator.
    uint256 public META_EVIDENCE_ID; // The ID of the MetaEvidence for disputes.

    IAMB public immutable amb; // ArbitraryMessageBridge contract address. TRUSTED.
    address public immutable homeProxy; // Address of the counter-party proxy on the Home Chain. TRUSTED.
    bytes32 public immutable homeChainId; // The chain ID where the home proxy is deployed.

    string public termsOfService; // The path for the Terms of Service for Kleros as an arbitrator for Realitio.

    // Multipliers are in basis points.
    uint64 private winnerMultiplier; // Multiplier for calculating the appeal fee that must be paid for the answer that was chosen by the arbitrator in the previous round.
    uint64 private loserMultiplier; // Multiplier for calculating the appeal fee that must be paid for the answer that the arbitrator didn't rule for in the previous round.

    mapping(uint256 => mapping(address => ArbitrationRequest)) public arbitrationRequests; // Maps arbitration ID to its data.
    mapping(uint256 => DisputeDetails) public disputeIDToDisputeDetails; // Maps external dispute ids to local arbitration ID and requester who was able to complete the arbitration request.
    mapping(uint256 => bool) public arbitrationIDToDisputeExists; // Whether a dispute has already been created for the given arbitration ID or not.
    mapping(uint256 => address) public arbitrationIDToRequester; // Maps arbitration ID to the requester who was able to complete the arbitration request.

    /* Events */

    /* Modifiers */

    modifier onlyArbitrator() {
        require(msg.sender == address(arbitrator), "Only arbitrator allowed");
        _;
    }

    modifier onlyGovernor() {
        require(msg.sender == governor, "Only governor allowed");
        _;
    }

    modifier onlyHomeProxy() {
        require(msg.sender == address(amb), "Only AMB allowed");
        require(amb.messageSourceChainId() == homeChainId, "Only home chain allowed");
        require(amb.messageSender() == homeProxy, "Only home proxy allowed");
        _;
    }

    /**
     * @notice Creates an arbitration proxy on the foreign chain.
     * @dev Contract will still require initialization before being usable.
     * @param _amb ArbitraryMessageBridge contract address.
     * @param _homeProxy The address of the proxy.
     * @param _homeChainId The chain ID where the home proxy is deployed.
     * @param _arbitrator Arbitrator contract address.
     * @param _arbitratorExtraData The extra data used to raise a dispute in the arbitrator.
     * @param _winnerMultiplier Multiplier for calculating the appeal cost of the winning answer.
     * @param _loserMultiplier Multiplier for calculation the appeal cost of the losing answer.
     */
    constructor(
        IAMB _amb,
        address _homeProxy,
        bytes32 _homeChainId,
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        string memory _metaEvidence,
        string memory _termsOfService,
        uint64 _winnerMultiplier,
        uint64 _loserMultiplier
    ) {
        amb = _amb;
        homeProxy = _homeProxy;
        homeChainId = _homeChainId;
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        termsOfService = _termsOfService;
        winnerMultiplier = _winnerMultiplier;
        loserMultiplier = _loserMultiplier;

        emit MetaEvidence(META_EVIDENCE_ID, _metaEvidence);
    }

    /* External and public */

    /**
     * @notice Changes the address of a new governor.
     * @param _governor The address of the new governor.
     */
    function changeGovernor(address _governor) external onlyGovernor {
        governor = _governor;
    }

    /**
     * @notice Changes the proportion of appeal fees that must be added to appeal cost for the winning party.
     * @param _winnerMultiplier The new winner multiplier value in basis points.
     */
    function changeWinnerMultiplier(uint64 _winnerMultiplier) external onlyGovernor {
        winnerMultiplier = _winnerMultiplier;
    }

    /**
     * @notice Changes the proportion of appeal fees that must be added to appeal cost for the losing party.
     * @param _loserMultiplier The new loser multiplier value in basis points.
     */
    function changeLoserMultiplier(uint64 _loserMultiplier) external onlyGovernor {
        loserMultiplier = _loserMultiplier;
    }

    // ************************ //
    // *    Realitio logic    * //
    // ************************ //

    /**
     * @notice Requests arbitration for the given question and contested answer.
     * @dev Can be executed only if the contract has been initialized.
     * @param _questionID The ID of the question.
     * @param _maxPrevious The maximum value of the previous bond for the question.
     */
    function requestArbitration(bytes32 _questionID, uint256 _maxPrevious) external payable override {
        require(!arbitrationIDToDisputeExists[uint256(_questionID)], "Dispute already created");

        ArbitrationRequest storage arbitration = arbitrationRequests[uint256(_questionID)][msg.sender];
        require(arbitration.status == Status.None, "Arbitration already requested");

        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        require(msg.value >= arbitrationCost, "Deposit value too low");

        arbitration.status = Status.Requested;
        arbitration.deposit = msg.value;

        bytes4 methodSelector = IHomeArbitrationProxy(0).receiveArbitrationRequest.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, _questionID, msg.sender, _maxPrevious);
        amb.requireToPassMessage(homeProxy, data, amb.maxGasPerTx());

        emit ArbitrationRequested(_questionID, msg.sender, _maxPrevious);
    }

    /**
     * @notice Receives the acknowledgement of the arbitration request for the given question and requester. TRUSTED.
     * @param _questionID The ID of the question.
     * @param _requester The requester.
     */
    function receiveArbitrationAcknowledgement(bytes32 _questionID, address _requester)
        external
        override
        onlyHomeProxy
    {
        uint256 arbitrationID = uint256(_questionID);
        ArbitrationRequest storage arbitration = arbitrationRequests[arbitrationID][_requester];
        require(arbitration.status == Status.Requested, "Invalid arbitration status");

        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);

        if (arbitration.deposit >= arbitrationCost) {
            try
                arbitrator.createDispute{value: arbitrationCost}(NUMBER_OF_CHOICES_FOR_ARBITRATOR, arbitratorExtraData)
            returns (uint256 disputeID) {
                DisputeDetails storage disputeDetails = disputeIDToDisputeDetails[disputeID];
                disputeDetails.arbitrationID = arbitrationID;
                disputeDetails.requester = _requester;

                arbitrationIDToDisputeExists[arbitrationID] = true;
                arbitrationIDToRequester[arbitrationID] = _requester;

                // At this point, arbitration.deposit is guaranteed to be greater than or equal to the arbitration cost.
                uint256 remainder = arbitration.deposit - arbitrationCost;

                arbitration.status = Status.Created;
                arbitration.deposit = 0;
                arbitration.disputeID = disputeID;
                arbitration.rounds.push();

                if (remainder > 0) {
                    payable(_requester).send(remainder);
                }

                emit ArbitrationCreated(_questionID, _requester, disputeID);
                emit Dispute(arbitrator, disputeID, META_EVIDENCE_ID, arbitrationID);
            } catch {
                arbitration.status = Status.Failed;
                emit ArbitrationFailed(_questionID, _requester);
            }
        } else {
            arbitration.status = Status.Failed;
            emit ArbitrationFailed(_questionID, _requester);
        }
    }

    /**
     * @notice Receives the cancelation of the arbitration request for the given question and requester. TRUSTED.
     * @param _questionID The ID of the question.
     * @param _requester The requester.
     */
    function receiveArbitrationCancelation(bytes32 _questionID, address _requester) external override onlyHomeProxy {
        uint256 arbitrationID = uint256(_questionID);
        ArbitrationRequest storage arbitration = arbitrationRequests[arbitrationID][_requester];
        require(arbitration.status == Status.Requested, "Invalid arbitration status");

        payable(_requester).send(arbitration.deposit);

        delete arbitrationRequests[arbitrationID][_requester];

        emit ArbitrationCanceled(_questionID, _requester);
    }

    /**
     * @notice Cancels the arbitration in case the dispute could not be created.
     * @param _questionID The ID of the question.
     * @param _requester The requester.
     */
    function handleFailedDisputeCreation(bytes32 _questionID, address _requester) external override {
        uint256 arbitrationID = uint256(_questionID);
        ArbitrationRequest storage arbitration = arbitrationRequests[arbitrationID][_requester];
        require(arbitration.status == Status.Failed, "Invalid arbitration status");

        payable(_requester).send(arbitration.deposit);

        delete arbitrationRequests[arbitrationID][_requester];

        bytes4 methodSelector = IHomeArbitrationProxy(0).receiveArbitrationFailure.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, _questionID, _requester);
        amb.requireToPassMessage(homeProxy, data, amb.maxGasPerTx());

        emit ArbitrationCanceled(_questionID, _requester);
    }

    // ********************************* //
    // *    Appeals and arbitration    * //
    // ********************************* //

    /**
     * @notice Takes up to the total amount required to fund an answer. Reimburses the rest. Creates an appeal if at least two answers are funded.
     * @param _arbitrationID The ID of the arbitration.
     * @param _answer One of the possible rulings the arbitrator can give that the funder considers to be the correct answer to the question.
     * @return Whether the answer was fully funded or not.
     */
    function fundAppeal(uint256 _arbitrationID, uint256 _answer) external payable override returns (bool) {
        address requester = arbitrationIDToRequester[_arbitrationID];
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][requester];
        require(arbitration.status == Status.Created, "No dispute to appeal.");
        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = arbitrator.appealPeriod(arbitration.disputeID);
        require(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd, "Appeal period is over.");

        // Answer is equal to ruling - 1.
        uint256 winner = arbitrator.currentRuling(arbitration.disputeID);
        uint256 multiplier;
        if (winner == _answer + 1) {
            multiplier = winnerMultiplier;
        } else {
            require(
                block.timestamp - appealPeriodStart < (appealPeriodEnd - appealPeriodStart) / 2,
                "Appeal period is over for loser."
            );
            multiplier = loserMultiplier;
        }

        Round storage round = arbitration.rounds[arbitration.rounds.length - 1];
        require(!round.hasPaid[_answer], "Appeal fee is already paid.");
        uint256 appealCost = arbitrator.appealCost(arbitration.disputeID, arbitratorExtraData);
        uint256 totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);

        // Take up to the amount necessary to fund the current round at the current costs.
        uint256 contribution =
            totalCost.subCap(round.paidFees[_answer]) > msg.value
                ? msg.value
                : totalCost.subCap(round.paidFees[_answer]);
        emit Contribution(_arbitrationID, arbitration.rounds.length - 1, _answer + 1, msg.sender, contribution);

        round.contributions[msg.sender][_answer] += contribution;
        round.paidFees[_answer] += contribution;
        if (round.paidFees[_answer] >= totalCost) {
            round.feeRewards += round.paidFees[_answer];
            round.fundedAnswers.push(_answer);
            round.hasPaid[_answer] = true;
            emit RulingFunded(_arbitrationID, arbitration.rounds.length - 1, _answer + 1);
        }

        if (round.fundedAnswers.length > 1) {
            // At least two sides are fully funded.
            arbitration.rounds.push();

            round.feeRewards = round.feeRewards.subCap(appealCost);
            arbitrator.appeal{value: appealCost}(arbitration.disputeID, arbitratorExtraData);
        }

        msg.sender.transfer(msg.value.subCap(contribution)); // Sending extra value back to contributor.
        return round.hasPaid[_answer];
    }

    /**
     * @notice Sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute. Reimburses contributions if there is no winner.
     * @param _arbitrationID The ID of the arbitration.
     * @param _beneficiary The address to send reward to.
     * @param _round The round from which to withdraw.
     * @param _answer The answer to query the reward from.
     * @return reward The withdrawn amount.
     */
    function withdrawFeesAndRewards(
        uint256 _arbitrationID,
        address payable _beneficiary,
        uint256 _round,
        uint256 _answer
    ) public override returns (uint256 reward) {
        address requester = arbitrationIDToRequester[_arbitrationID];
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][requester];
        Round storage round = arbitration.rounds[_round];
        require(arbitration.status == Status.Ruled, "Dispute not resolved");
        // Allow to reimburse if funding of the round was unsuccessful.
        if (!round.hasPaid[_answer]) {
            reward = round.contributions[_beneficiary][_answer];
        } else if (!round.hasPaid[arbitration.answer]) {
            // Reimburse unspent fees proportionally if the ultimate winner didn't pay appeal fees fully.
            // Note that if only one side is funded it will become a winner and this part of the condition won't be reached.
            reward = round.fundedAnswers.length > 1
                ? (round.contributions[_beneficiary][_answer] * round.feeRewards) /
                    (round.paidFees[round.fundedAnswers[0]] + round.paidFees[round.fundedAnswers[1]])
                : 0;
        } else if (arbitration.answer == _answer) {
            // Reward the winner.
            reward = round.paidFees[_answer] > 0
                ? (round.contributions[_beneficiary][_answer] * round.feeRewards) / round.paidFees[_answer]
                : 0;
        }

        if (reward != 0) {
            round.contributions[_beneficiary][_answer] = 0;
            _beneficiary.transfer(reward);
            emit Withdrawal(_arbitrationID, _round, _answer + 1, _beneficiary, reward);
        }
    }

    /**
     * @notice Allows to withdraw any reimbursable fees or rewards after the dispute gets solved for multiple ruling options (answers) at once.
     * @dev This function is O(n) where n is the number of queried answers.
     * @dev This could exceed gas limits, therefore this function should be used only as a utility and not be relied upon by other contracts.
     * @param _arbitrationID The ID of the arbitration.
     * @param _beneficiary The address that made contributions.
     * @param _round The round from which to withdraw.
     * @param _contributedTo Answers that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForMultipleRulings(
        uint256 _arbitrationID,
        address payable _beneficiary,
        uint256 _round,
        uint256[] memory _contributedTo
    ) public override {
        for (uint256 contributionNumber = 0; contributionNumber < _contributedTo.length; contributionNumber++) {
            withdrawFeesAndRewards(_arbitrationID, _beneficiary, _round, _contributedTo[contributionNumber]);
        }
    }

    /**
     * @notice Allows to withdraw any rewards or reimbursable fees for multiple rulings options (answers) and for all rounds at once.
     * @dev This function is O(n*m) where n is the total number of rounds and m is the number of queried answers.
     * @dev This could exceed gas limits, therefore this function should be used only as a utility and not be relied upon by other contracts.
     * @param _arbitrationID The ID of the arbitration.
     * @param _beneficiary The address that made contributions.
     * @param _contributedTo Answers that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForAllRounds(
        uint256 _arbitrationID,
        address payable _beneficiary,
        uint256[] memory _contributedTo
    ) external override {
        address requester = arbitrationIDToRequester[_arbitrationID];
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][requester];

        for (uint256 roundNumber = 0; roundNumber < arbitration.rounds.length; roundNumber++) {
            withdrawFeesAndRewardsForMultipleRulings(_arbitrationID, _beneficiary, roundNumber, _contributedTo);
        }
    }

    /**
     * @notice Allows to submit evidence for a particular question.
     * @param _arbitrationID The ID of the arbitration related to the question.
     * @param _evidenceURI Link to evidence.
     */
    function submitEvidence(uint256 _arbitrationID, string calldata _evidenceURI) external override {
        address requester = arbitrationIDToRequester[_arbitrationID];
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][requester];
        require(arbitration.status == Status.Created, "The status should be Created.");

        if (bytes(_evidenceURI).length > 0) {
            emit Evidence(arbitrator, _arbitrationID, msg.sender, _evidenceURI);
        }
    }

    /**
     * @notice Rules a specified dispute.
     * @dev Note that 0 is reserved for "Unable/refused to arbitrate" and we shift it to `uint(-1)` which has a similar connotation in Realitio.
     * @param _disputeID The ID of the dispute in the ERC792 arbitrator.
     * @param _ruling The ruling given by the arbitrator.
     */
    function rule(uint256 _disputeID, uint256 _ruling) external override onlyArbitrator {
        DisputeDetails storage disputeDetails = disputeIDToDisputeDetails[_disputeID];
        uint256 arbitrationID = disputeDetails.arbitrationID;
        address requester = disputeDetails.requester;

        ArbitrationRequest storage arbitration = arbitrationRequests[arbitrationID][requester];
        require(arbitration.status == Status.Created, "Invalid arbitration status");
        uint256 finalRuling = _ruling;

        // If one side paid its fees, the ruling is in its favor. Note that if the other side had also paid, an appeal would have been created.
        Round storage round = arbitration.rounds[arbitration.rounds.length - 1];
        if (round.fundedAnswers.length == 1) finalRuling = round.fundedAnswers[0] + 1;

        // Realitio ruling is shifted by 1 compared to Kleros.
        arbitration.answer = finalRuling - 1;
        arbitration.status = Status.Ruled;

        bytes4 methodSelector = IHomeArbitrationProxy(0).receiveArbitrationAnswer.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, bytes32(arbitrationID), bytes32(arbitration.answer));
        amb.requireToPassMessage(homeProxy, data, amb.maxGasPerTx());

        emit Ruling(arbitrator, _disputeID, _ruling);
    }

    /* External Views */

    /**
     * @notice Returns stake multipliers.
     * @return winner Winners stake multiplier.
     * @return loser Losers stake multiplier.
     * @return shared Multiplier when it's a tie. Is not used in this contract.
     * @return divisor Multiplier divisor.
     */
    function getMultipliers()
        external
        view
        override
        returns (
            uint256 winner,
            uint256 loser,
            uint256 shared,
            uint256 divisor
        )
    {
        return (winnerMultiplier, loserMultiplier, 0, MULTIPLIER_DIVISOR);
    }

    /**
     * @notice Returns number of possible ruling options. Valid rulings are [0, return value].
     * @param _arbitrationID The ID of the arbitration.
     * @return count The number of ruling options.
     */
    function numberOfRulingOptions(uint256 _arbitrationID) external pure override returns (uint256) {
        return NUMBER_OF_CHOICES_FOR_ARBITRATOR;
    }

    /**
     * @notice Gets the fee to create a dispute.
     * @param _questionID the ID of the question.
     * @return The fee to create a dispute.
     */
    function getDisputeFee(bytes32 _questionID) external view override returns (uint256) {
        return arbitrator.arbitrationCost(arbitratorExtraData);
    }

    /**
     * @notice Gets the number of rounds of the specific question.
     * @param _arbitrationID The ID of the arbitration.
     * @return The number of rounds.
     */
    function getNumberOfRounds(uint256 _arbitrationID) external view returns (uint256) {
        address requester = arbitrationIDToRequester[_arbitrationID];
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][requester];
        return arbitration.rounds.length;
    }

    /**
     * @notice Gets the information of a round of a question.
     * @param _arbitrationID The ID of the arbitration.
     * @param _round The round to query.
     * @return paidFees The amount of fees paid for each fully funded answer.
     * @return feeRewards The amount of fees that will be used as rewards.
     * @return fundedAnswers IDs of fully funded answers.
     */
    function getRoundInfo(uint256 _arbitrationID, uint256 _round)
        external
        view
        returns (
            uint256[] memory paidFees,
            uint256 feeRewards,
            uint256[] memory fundedAnswers
        )
    {
        address requester = arbitrationIDToRequester[_arbitrationID];
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][requester];
        Round storage round = arbitration.rounds[_round];
        fundedAnswers = round.fundedAnswers;

        paidFees = new uint256[](round.fundedAnswers.length);

        for (uint256 i = 0; i < round.fundedAnswers.length; i++) {
            paidFees[i] = round.paidFees[round.fundedAnswers[i]];
        }

        feeRewards = round.feeRewards;
    }

    /**
     * @notice Gets the information of a round of a question for a specific answer choice.
     * @param _arbitrationID The ID of the arbitration.
     * @param _round The round to query.
     * @param _answer The answer choice to get funding status for.
     * @return raised The amount paid for this answer.
     * @return fullyFunded Whether the answer is fully funded or not.
     */
    function getFundingStatus(
        uint256 _arbitrationID,
        uint256 _round,
        uint256 _answer
    ) external view returns (uint256 raised, bool fullyFunded) {
        address requester = arbitrationIDToRequester[_arbitrationID];
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][requester];
        Round storage round = arbitration.rounds[_round];

        raised = round.paidFees[_answer];
        fullyFunded = round.hasPaid[_answer];
    }

    /**
     * @notice Gets contributions to the answers that are fully funded.
     * @param _arbitrationID The ID of the arbitration.
     * @param _round The round to query.
     * @param _contributor The address whose contributions to query.
     * @return fundedAnswers IDs of the answers that are fully funded.
     * @return contributions The amount contributed to each funded answer by the contributor.
     */
    function getContributionsToSuccessfulFundings(
        uint256 _arbitrationID,
        uint256 _round,
        address _contributor
    ) external view returns (uint256[] memory fundedAnswers, uint256[] memory contributions) {
        address requester = arbitrationIDToRequester[_arbitrationID];
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][requester];
        Round storage round = arbitration.rounds[_round];

        fundedAnswers = round.fundedAnswers;
        contributions = new uint256[](round.fundedAnswers.length);

        for (uint256 i = 0; i < contributions.length; i++) {
            contributions[i] = round.contributions[_contributor][fundedAnswers[i]];
        }
    }

    /**
     * @notice Casts question ID into uint256 thus returning the related arbitration ID.
     * @param _questionID The ID of the question.
     * @return The ID of the arbitration.
     */
    function questionIDToArbitrationID(bytes32 _questionID) external pure returns (uint256) {
        return uint256(_questionID);
    }

    /**
     * @dev Maps external (arbitrator side) dispute id to local (arbitrable) dispute id.
     * @param _externalDisputeID Dispute id as in arbitrator side.
     * @return localDisputeID Dispute id as in arbitrable contract.
     */
    function externalIDtoLocalID(uint256 _externalDisputeID) external view override returns (uint256 localDisputeID) {
        return disputeIDToDisputeDetails[_externalDisputeID].arbitrationID;
    }
}
