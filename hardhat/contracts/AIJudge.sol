// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/**
 * @title AIJudge
 * @notice Privacy-preserving bounty judge using commit-reveal scheme.
 *
 * Lifecycle per bounty:
 *   1. Owner creates bounty with title, rubric, submission deadline, reveal deadline.
 *   2. Participants call submitCommitment() before submissionDeadline.
 *      They store their answer OFF-CHAIN and submit only a commitment hash.
 *   3. After submissionDeadline, reveal phase opens.
 *      Participants call revealAnswer() before revealDeadline.
 *      Contract verifies commitment hash and stores plaintext answer on-chain.
 *   4. After revealDeadline, owner calls judgeAll() — sends all revealed answers to Ritual LLM.
 *   5. Owner calls finalizeWinner() based on AI output.
 *
 * Commitment scheme:
 *   commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
 *   Including msg.sender prevents front-running: you can't copy someone's commitment
 *   and submit it as your own.
 */
contract AIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    // -------------------------------------------------------------------------
    // Data structures
    // -------------------------------------------------------------------------

    struct Commitment {
        bytes32 hash;       // keccak256(answer, salt, submitter, bountyId)
        bool revealed;
    }

    struct Submission {
        address submitter;
        string answer;      // empty until revealed
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline; // commit phase ends here
        uint256 revealDeadline;     // reveal phase ends here
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        // commitments[i] maps to submissions[i] by index
        Commitment[] commitments;
        Submission[] submissions;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) public bounties;

    // track which addresses have already committed per bounty
    mapping(uint256 => mapping(address => bool)) public hasCommitted;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    // -------------------------------------------------------------------------
    // Core functions
    // -------------------------------------------------------------------------

    /**
     * @notice Create a new bounty with two deadlines.
     * @param title Human-readable title shown to participants.
     * @param rubric Judging criteria passed to the LLM.
     * @param submissionDeadline Unix timestamp: end of commit phase.
     * @param revealDeadline Unix timestamp: end of reveal phase. Must be > submissionDeadline.
     */
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(submissionDeadline > block.timestamp, "submission deadline must be in future");
        require(revealDeadline > submissionDeadline, "reveal deadline must be after submission deadline");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.submissionDeadline = submissionDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(bountyId, msg.sender, title, msg.value, submissionDeadline, revealDeadline);
    }

    /**
     * @notice Submit a commitment hash. Called during commit phase (before submissionDeadline).
     * @dev Off-chain: participant computes keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
     *      and submits that hash. The answer and salt remain private until reveal phase.
     * @param bountyId Target bounty.
     * @param commitment keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
     */
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.submissionDeadline, "commit phase closed");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(!hasCommitted[bountyId][msg.sender], "already committed");
        require(bounty.commitments.length < MAX_SUBMISSIONS, "submission cap reached");

        uint256 idx = bounty.commitments.length;

        bounty.commitments.push(Commitment({hash: commitment, revealed: false}));
        bounty.submissions.push(Submission({submitter: msg.sender, answer: ""}));

        hasCommitted[bountyId][msg.sender] = true;

        emit CommitmentSubmitted(bountyId, idx, msg.sender);
    }

    /**
     * @notice Reveal the answer after commit phase ends. Called during reveal phase.
     * @dev Contract recomputes the commitment hash and checks it matches what was submitted.
     *      If valid, the plaintext answer is stored on-chain for AI judging.
     * @param bountyId Target bounty.
     * @param answer Plaintext answer (must match what was hashed during commit).
     * @param salt Random bytes32 used during commit to prevent rainbow table attacks.
     */
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.submissionDeadline, "reveal phase not started");
        require(block.timestamp < bounty.revealDeadline, "reveal phase closed");
        require(!bounty.judged, "already judged");
        require(bytes(answer).length > 0, "answer cannot be empty");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        // Find the commitment index belonging to msg.sender
        uint256 idx = _findCommitmentIndex(bountyId, msg.sender);

        Commitment storage c = bounty.commitments[idx];
        require(!c.revealed, "already revealed");

        // Recompute commitment and verify
        bytes32 expected = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId));
        require(expected == c.hash, "commitment mismatch: wrong answer or salt");

        c.revealed = true;
        bounty.submissions[idx].answer = answer;

        emit AnswerRevealed(bountyId, idx, msg.sender);
    }

    /**
     * @notice Send all revealed answers to Ritual LLM for batch judging.
     * @dev Only callable by bounty owner after reveal phase ends.
     *      Only submissions that were successfully revealed are eligible.
     *      llmInput should encode the rubric and all revealed answers as a single prompt
     *      for batch evaluation — one LLM call, not one per answer.
     * @param bountyId Target bounty.
     * @param llmInput ABI-encoded input for Ritual's LLM_INFERENCE_PRECOMPILE.
     */
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.revealDeadline, "reveal phase not over");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(_revealedCount(bounty) > 0, "no revealed submissions");

        bytes memory output = _executePrecompile(LLM_INFERENCE_PRECOMPILE, llmInput);

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,
        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    /**
     * @notice Finalize winner and transfer reward.
     * @dev winnerIndex must correspond to a submission that was actually revealed.
     *      The human owner makes the final call based on AI output — they are accountable
     *      for verifying the AI's recommendation before sending funds.
     * @param bountyId Target bounty.
     * @param winnerIndex Index in submissions array of the winner.
     */
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid winner index");

        // Must pick a submission that was actually revealed
        require(bounty.commitments[winnerIndex].revealed, "winner did not reveal");

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.submissions[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 submissionDeadline,
            uint256 revealDeadline,
            bool judged,
            bool finalized,
            uint256 commitmentCount,
            uint256 revealedCount,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage bounty = bounties[bountyId];

        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.submissionDeadline,
            bounty.revealDeadline,
            bounty.judged,
            bounty.finalized,
            bounty.commitments.length,
            _revealedCount(bounty),
            bounty.winnerIndex,
            bounty.aiReview
        );
    }

    /**
     * @notice Get a submission. Answer is empty string until revealed.
     */
    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, string memory answer, bool revealed)
    {
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.submissions.length, "invalid index");

        return (
            bounty.submissions[index].submitter,
            bounty.submissions[index].answer,
            bounty.commitments[index].revealed
        );
    }

    /**
     * @notice Helper for participants: compute their commitment hash off-chain equivalent.
     *         Can also be called on-chain for testing. Not used in production flow.
     */
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, submitter, bountyId));
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _findCommitmentIndex(
        uint256 bountyId,
        address submitter
    ) internal view returns (uint256) {
        Bounty storage bounty = bounties[bountyId];
        for (uint256 i = 0; i < bounty.submissions.length; i++) {
            if (bounty.submissions[i].submitter == submitter) {
                return i;
            }
        }
        revert("no commitment found for caller");
    }

    function _revealedCount(Bounty storage bounty) internal view returns (uint256 count) {
        for (uint256 i = 0; i < bounty.commitments.length; i++) {
            if (bounty.commitments[i].revealed) count++;
        }
    }
}
