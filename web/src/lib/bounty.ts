import type { Address } from "viem";

/** Parsed shape of the `getBounty` tuple return value. */
export type Bounty = {
  owner: Address;
  title: string;
  rubric: string;
  reward: bigint;
  submissionDeadline: bigint;
  revealDeadline: bigint;
  judged: boolean;
  finalized: boolean;
  commitmentCount: bigint;
  revealedCount: bigint;
  winnerIndex: bigint;
  aiReview: `0x${string}`;
};

/** getBounty returns a positional tuple — map it to a named object. */
export function parseBounty(
  raw: readonly [
    Address,
    string,
    string,
    bigint,
    bigint,
    bigint,
    boolean,
    boolean,
    bigint,
    bigint,
    bigint,
    `0x${string}`,
  ],
): Bounty {
  const [
    owner,
    title,
    rubric,
    reward,
    submissionDeadline,
    revealDeadline,
    judged,
    finalized,
    commitmentCount,
    revealedCount,
    winnerIndex,
    aiReview,
  ] = raw;
  return {
    owner,
    title,
    rubric,
    reward,
    submissionDeadline,
    revealDeadline,
    judged,
    finalized,
    commitmentCount,
    revealedCount,
    winnerIndex,
    aiReview,
  };
}

export type BountyStatus = "commit" | "reveal" | "judging" | "judged" | "finalized";

export function getBountyStatus(b: Bounty, nowSeconds = Date.now() / 1000): BountyStatus {
  if (b.finalized) return "finalized";
  if (b.judged) return "judged";
  if (Number(b.revealDeadline) <= nowSeconds) return "judging";
  if (Number(b.submissionDeadline) <= nowSeconds) return "reveal";
  return "commit";
}

export const STATUS_META: Record<
  BountyStatus,
  { label: string; tone: "green" | "amber" | "indigo" | "zinc" | "red" }
> = {
  commit: { label: "Commit Phase", tone: "green" },
  reveal: { label: "Reveal Phase", tone: "amber" },
  judging: { label: "Judging", tone: "indigo" },
  judged: { label: "Judged", tone: "indigo" },
  finalized: { label: "Finalized", tone: "zinc" },
};

/** Can a participant still submit a commitment? */
export function canSubmit(b: Bounty, nowSeconds = Date.now() / 1000): boolean {
  return !b.judged && !b.finalized && Number(b.submissionDeadline) > nowSeconds;
}

/** Is the bounty in the reveal phase? */
export function isRevealPhase(b: Bounty, nowSeconds = Date.now() / 1000): boolean {
  return (
    !b.judged &&
    !b.finalized &&
    Number(b.submissionDeadline) <= nowSeconds &&
    Number(b.revealDeadline) > nowSeconds
  );
}

/** Is the bounty in the commit phase? */
export function isCommitPhase(b: Bounty, nowSeconds = Date.now() / 1000): boolean {
  return !b.judged && !b.finalized && Number(b.submissionDeadline) > nowSeconds;
}

/** Is the bounty ready for judging (reveal phase over, not yet judged)? */
export function isJudgePhase(b: Bounty, nowSeconds = Date.now() / 1000): boolean {
  return (
    !b.judged &&
    !b.finalized &&
    Number(b.submissionDeadline) <= nowSeconds &&
    Number(b.revealDeadline) <= nowSeconds
  );
}
