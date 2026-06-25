# AI Bounty Judge - Commit-Reveal

Privacy-preserving bounty system built on Ritual Chain. Submissions stay hidden until judging is complete using a commit-reveal scheme.

## Deployed Contract

- **Address:** `0x1C848b34270bF3A847f07d68069BF735DACc4e66`
- **Network:** Ritual Chain (Chain ID 1979)
- **Track:** Required Track - Commit-Reveal Bounty

## How It Works

Participants submit a commitment hash during the submission phase. After the deadline, they reveal their answer and salt. The contract verifies the hash matches before making the answer eligible for AI judging.

commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))

See hardhat/SUBMISSION_README.md for full lifecycle, architecture note, test plan, and reflection.

## Structure

- /hardhat - Solidity contract with commit-reveal implementation
- /web - Next.js frontend with wagmi + viem

## Running Locally

cd hardhat && pnpm install && npx hardhat compile
cd web && pnpm install && pnpm dev