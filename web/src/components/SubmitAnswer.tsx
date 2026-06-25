"use client";

import { useState, useEffect, useCallback } from "react";
import { useAccount } from "wagmi";
import { keccak256, encodePacked } from "viem";
import { useNow } from "@/hooks/useNow";
import aiJudgeAbi from "@/abi/AIJudge";
import { contractAddress } from "@/config/contract";
import { ritualChain } from "@/config/wagmi";
import { isCommitPhase, isRevealPhase, type Bounty } from "@/lib/bounty";
import { useWriteTx } from "@/hooks/useWriteTx";
import {
  Card,
  CardHeader,
  CardBody,
  Field,
  Textarea,
  Button,
  TxStatus,
  Notice,
} from "@/components/ui";

const explorerBase = ritualChain.blockExplorers?.default.url;

function storageKey(bountyId: bigint): string {
  return `bounty-commit-${bountyId.toString()}`;
}

function loadDraft(bountyId: bigint): { answer: string; salt: string } | null {
  try {
    const raw = localStorage.getItem(storageKey(bountyId));
    return raw ? (JSON.parse(raw) as { answer: string; salt: string }) : null;
  } catch {
    return null;
  }
}

function saveDraft(bountyId: bigint, answer: string, salt: string) {
  localStorage.setItem(
    storageKey(bountyId),
    JSON.stringify({ answer, salt }),
  );
}

function clearDraft(bountyId: bigint) {
  localStorage.removeItem(storageKey(bountyId));
}

function randomSalt(): `0x${string}` {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return `0x${Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")}` as `0x${string}`;
}

export function SubmitAnswer({
  bountyId,
  bounty,
  onSubmitted,
}: {
  bountyId: bigint;
  bounty: Bounty;
  onSubmitted: () => void;
}) {
  const { isConnected, address } = useAccount();
  const [answer, setAnswer] = useState("");
  const [salt, setSalt] = useState<`0x${string}`>(randomSalt());
  const now = useNow();
  const nowSeconds = now / 1000;
  const commitTx = useWriteTx(() => {
    setAnswer("");
    onSubmitted();
  });
  const revealTx = useWriteTx(() => {
    clearDraft(bountyId);
    setAnswer("");
    onSubmitted();
  });

  const commitPhase = isCommitPhase(bounty, nowSeconds);
  const revealPhase = isRevealPhase(bounty, nowSeconds);

  // Load saved draft on mount / bountyId change for reveal phase
  useEffect(() => {
    const draft = loadDraft(bountyId);
    if (draft) {
      setAnswer(draft.answer);
      setSalt(draft.salt as `0x${string}`);
    } else {
      setSalt(randomSalt());
    }
  }, [bountyId]);

  // Compute the commitment hash
  const computeCommitment = useCallback(
    (ans: string, slt: `0x${string}`): `0x${string}` | null => {
      if (!ans.trim() || !address) return null;
      try {
        return keccak256(
          encodePacked(
            ["string", "bytes32", "address", "uint256"],
            [ans.trim(), slt, address, bountyId],
          ),
        );
      } catch {
        return null;
      }
    },
    [address, bountyId],
  );

  // ---- Commit phase ----

  async function handleCommit(e: React.FormEvent) {
    e.preventDefault();
    if (!answer.trim() || !contractAddress || !address) return;

    const commitment = computeCommitment(answer, salt);
    if (!commitment) return;

    try {
      await commitTx.run({
        address: contractAddress,
        abi: aiJudgeAbi,
        functionName: "submitCommitment",
        args: [bountyId, commitment],
        chainId: ritualChain.id,
      });
      // Persist draft after successful submission
      saveDraft(bountyId, answer.trim(), salt);
    } catch {
      /* surfaced via tx.state */
    }
  }

  // ---- Reveal phase ----

  async function handleReveal(e: React.FormEvent) {
    e.preventDefault();
    if (!answer.trim() || !contractAddress) return;

    // Recompute salt from localStorage if available for convenience
    const draft = loadDraft(bountyId);
    const revealSalt = draft?.salt
      ? (draft.salt as `0x${string}`)
      : salt;

    try {
      await revealTx.run({
        address: contractAddress,
        abi: aiJudgeAbi,
        functionName: "revealAnswer",
        args: [bountyId, answer.trim(), revealSalt],
        chainId: ritualChain.id,
      });
    } catch {
      /* surfaced via tx.state */
    }
  }

  // ---- Nothing to show outside of commit / reveal phases ----
  if (!commitPhase && !revealPhase) return null;

  return (
    <Card>
      {commitPhase ? (
        <>
          <CardHeader
            title="Submit a commitment"
            subtitle="Your answer stays hidden until the reveal phase."
          />
          <CardBody>
            <form onSubmit={handleCommit} className="space-y-3">
              <Field label="Your answer">
                <Textarea
                  value={answer}
                  onChange={(e) => setAnswer(e.target.value)}
                  rows={5}
                  placeholder="Write your submission…"
                />
              </Field>

              <Notice tone="amber">
                <strong>Save your answer and salt.</strong> You will need them to
                reveal after the submission deadline. This is stored in your
                browser's localStorage.
              </Notice>

              <Button
                type="submit"
                disabled={
                  !isConnected || !answer.trim() || commitTx.isBusy
                }
                className="w-full"
              >
                {commitTx.isBusy ? "Committing…" : "Submit commitment"}
              </Button>

              {!isConnected && (
                <p className="text-xs text-zinc-500">
                  Connect your wallet to submit.
                </p>
              )}

              <TxStatus
                state={commitTx.state}
                error={commitTx.error}
                hash={commitTx.hash}
                explorerBase={explorerBase}
              />
            </form>
          </CardBody>
        </>
      ) : null}

      {revealPhase ? (
        <>
          <CardHeader
            title="Reveal your answer"
            subtitle="The commit phase is over. Submit your plaintext answer to be judged."
          />
          <CardBody>
            <form onSubmit={handleReveal} className="space-y-3">
              <Field label="Your answer">
                <Textarea
                  value={answer}
                  onChange={(e) => setAnswer(e.target.value)}
                  rows={5}
                  placeholder="Paste your previously committed answer…"
                />
              </Field>

              <Button
                type="submit"
                disabled={!isConnected || !answer.trim() || revealTx.isBusy}
                className="w-full"
              >
                {revealTx.isBusy ? "Revealing…" : "Reveal answer"}
              </Button>

              {!isConnected && (
                <p className="text-xs text-zinc-500">
                  Connect your wallet to reveal.
                </p>
              )}

              <TxStatus
                state={revealTx.state}
                error={revealTx.error}
                hash={revealTx.hash}
                explorerBase={explorerBase}
              />
            </form>
          </CardBody>
        </>
      ) : null}
    </Card>
  );
}
