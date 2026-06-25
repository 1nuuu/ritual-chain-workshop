# AI Bounty Judge Commit-Reveal Submission

### 1. Bounty Lifecycle
The lifecycle of a bounty progresses through distinct phases:
1. **Creation (`createBounty`)**: The owner deploys a bounty by specifying a `title`, `rubric`, `submissionDeadline` (end of commit phase), and `revealDeadline` (end of reveal phase). They fund the bounty with a reward (`msg.value`).
2. **Commit Phase (`submitCommitment`)**: Allowed only before `submissionDeadline`. Participants generate a commitment hash off-chain and submit it. Plaintext answers remain private.
3. **Reveal Phase (`revealAnswer`)**: Allowed only after `submissionDeadline` and before `revealDeadline`. Participants reveal their plaintext `answer` and `salt`. The contract verifies the data against the stored commitment hash.
4. **Judging (`judgeAll`)**: Allowed only after `revealDeadline`. The owner sends all revealed answers to the Ritual LLM in a single batch inference precompile call.
5. **Finalization (`finalizeWinner`)**: The owner selects the winner using the index of a successfully revealed submission, transferring the reward to them.

---

### 2. Commitment Scheme
Commitments are computed as:
```solidity
commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
```
- **Why `msg.sender`?** Prevents front-running. Without it, a malicious actor could copy a participant's commitment hash from the mempool or tx history and submit it as their own, then copy their plaintext answer and salt when revealed.
- **Why `bountyId`?** Prevents cross-bounty replay attacks. Without it, a participant could replay a successful commitment hash and answer from an old bounty on a new one.
- **Why `salt`?** Prevents rainbow table attacks. Answers to bounty questions are often short or predictable. An attacker could precompute hashes for common answers and identify matching commitments. A random 32-byte salt ensures the pre-image remains unguessable.

---

### 3. Architecture Note: Commit-Reveal vs Ritual-Native (TEE)
| Dimension | Commit-Reveal Approach | Ritual-Native TEE Approach |
| :--- | :--- | :--- |
| **Plaintext Location** | On-chain (after reveal phase opens). | Off-chain inside secure enclave / TEE. |
| **On-chain Storage** | Commitments first, then plaintext answers. | Only commitments / encrypted inputs. |
| **LLM Inference** | Receives all plaintext answers in a batch. | Receives decrypted inputs in enclave. |
| **Privacy Window** | Temporary (answers public at reveal). | Permanent (answers never public). |
| **Trade-offs** | Native EVM-compatible; doesn't hide revealed inputs from public nodes. | Requires TEE/Ritual nodes; guarantees input privacy from nodes. |

The commit-reveal scheme is highly portable since it runs on any standard EVM blockchain without custom hardware dependencies. However, it compromises participant privacy once the reveal phase begins, meaning participants can see rival answers before judging completes. 

A Ritual-Native TEE approach solves this by processing answers inside a Trusted Execution Environment (TEE). Plaintext answers are sent encrypted and decrypted only inside the secure enclave during inference. This keeps submissions entirely hidden from the public and node operators throughout the lifetime of the bounty, but ties the system's security to the hardware guarantees of enclaves and Ritual-specific infrastructure.

---

### 4. Test Plan

| Phase | Test Case | Expected Result |
| :--- | :--- | :--- |
| **Commit** | Commit before `submissionDeadline` | Success. Commitment hash stored, event emitted. |
| **Commit** | Commit after `submissionDeadline` | Revert: `"commit phase closed"` |
| **Commit** | Double commit same address | Revert: `"already committed"` |
| **Reveal** | Reveal before `submissionDeadline` | Revert: `"reveal phase not started"` |
| **Reveal** | Reveal after `revealDeadline` | Revert: `"reveal phase closed"` |
| **Reveal** | Reveal with correct answer + salt | Success. Plaintext stored, event emitted. |
| **Reveal** | Reveal with wrong answer | Revert: `"commitment mismatch: wrong answer or salt"` |
| **Reveal** | Reveal with wrong salt | Revert: `"commitment mismatch: wrong answer or salt"` |
| **Reveal** | Front-run: copy another's commitment | Revert on reveal: msg.sender mismatch makes hash invalid. |
| **Judging** | Call `judgeAll` before `revealDeadline` | Revert: `"reveal phase not over"` |
| **Judging** | Call `judgeAll` with zero valid reveals | Revert: `"no revealed submissions"` |
| **Finalization** | Call `finalizeWinner` for index that didn't reveal | Revert: `"winner did not reveal"` |
| **Finalization** | Call `finalizeWinner` with valid index | Success. Transfer reward, set `finalized = true`. |

---

### 5. Reflection
In any web3 bounty system, design should prioritize keeping submission contents completely hidden until the evaluation phase is locked. If answers are public, later submitters will plagiarize, adapt, and refine early submissions, creating a penalty for submitting early. 

However, once evaluation is locked and judging begins, submissions should become transparent to allow public verification of the results. The judging criteria (the rubric) must remain public to set expectations, but the actual evaluation input to the AI should be audited. 

While AI is excellent for sorting and analyzing large volumes of text to identify high-quality answers, it cannot hold ultimate authority over funds. AI models can hallucinate, be manipulated via prompt injection, or fail due to network precompile hiccups. A human owner must remain the final arbiter of payouts, holding veto power and responsibility for auditing the AI's selection before triggering transfers.
