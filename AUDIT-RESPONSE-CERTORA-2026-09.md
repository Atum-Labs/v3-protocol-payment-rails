# Certora draft report — Atum Module: response and fixes

**Scope** `credit-cooperative/v3-protocol-payment-rails` @ `a5e33f361c04257d92de86d456c934528a0cc925` (PR #16)

**Report** Certora draft, September 2026 — 11 findings: 0 critical, 0 high, 1 medium, 4 low, 6 informational

**Status** 10 of 11 fixed. **M-01, the sole Medium, is only partially addressed: the cross-module replay is not prevented on-chain**, and the control relied on is a deployment constraint rather than code. The reasoning is in the M-01 section and should be read before the summary table is taken at face value.

Each fix is accompanied by a regression test. `forge test`: **657 pass, 0 fail, 57 skipped** across 104 suites. `solhint`: 0 errors.

---

## Summary

| ID   | Severity | Response                                                     |
| ---- | -------- | ------------------------------------------------------------ |
| M-01 | Medium   | **Partial** — replay not prevented on-chain; see below       |
| L-01 | Low      | Fixed — creation restricted to the PaymentRails owner        |
| L-02 | Low      | Fixed — `syncAllowance`, keeper-gated                        |
| L-03 | Low      | Fixed — addressed together with I-05                         |
| L-04 | Low      | Fixed — by a different mechanism than recommended; see below |
| I-01 | Info     | Resolved by giving the unused modifier a caller              |
| I-02 | Info     | Fixed — `renounceOwnership` reverts                          |
| I-03 | Info     | Fixed — initial keeper emitted by the module and the factory |
| I-04 | Info     | Fixed — CREATE2 salt bound to the caller                     |
| I-05 | Info     | Fixed — addressed together with L-03                         |
| I-06 | Info     | Fixed — sender debit now checked                             |

**A key-management constraint carries M-01 on its own.** The replay is only possible between modules that share a keeper, so modules must be issued distinct keepers. This is a deployment-time constraint on key management, **not enforced on-chain**. Unlike in earlier drafts of this response, it is not a stopgap alongside a code fix — it is the only thing preventing the finding, because no on-chain binding ships. See M-01 below.

Two additional observations arising from the review:

1. **L-03 and I-05 describe the same defect from opposite sides**, and are resolved by a single change.
2. **`permit2DomainSeparator` was unused state** — assigned in the constructor, exposed by a getter, and read nowhere. Removed, and the domain separator is now read live inside `isValidSignature` instead (M-01).

---

## M-01 — cross-module signature replay (Medium)

**Status: partially addressed. The cross-module replay is NOT prevented on-chain.** The recommended remediation was implemented and then withdrawn; what replaces it is narrower. This section states what the contracts now do, what they deliberately do not do, and why.

**Mechanism.** `isValidSignature` validated the caller's raw hash directly against the keeper. The digest Permit2 constructs does not contain the owner, and Permit2 tracks nonces per owner. Two modules sharing a keeper therefore accepted the identical `(hash, signature)` pair, and one authorisation could be spent once at each.

**Why the recommended EIP-712 wrap was withdrawn.** It was implemented, and it worked: the incoming hash was re-hashed under the module's own EIP-712 domain, binding `address(this)` and `chainid` into the signed payload. The reason it is not shipped is that it is incompatible with how the keeper is being built. The keeper is a policy-gated signer: before releasing a signature it inspects the `PermitWitnessTransferFrom` struct — spender, permitted token and amount, witness members — and refuses anything that does not match an expected payment. Wrapping the digest replaces that struct with a single opaque `bytes32` as the only thing the keeper ever signs, so the policy engine has nothing left to inspect and its checks degrade to a no-op. Trading an enforced off-chain authorisation policy for an on-chain replay binding is not obviously a net gain, and it is not a trade worth making silently.

**What the contracts now enforce: the Permit2 domain separator.** `isValidSignature` cannot take `hash` apart — it is a keccak output — so the keeper supplies the `PermitWitnessTransferFrom` struct hash alongside its signature, in an `encodeKeeperSignature(structHash, signature)` envelope, and the module rebuilds the digest:

```
keccak256(0x1901 ‖ IPermit2(permit2).DOMAIN_SEPARATOR() ‖ structHash) == hash
```

A hash that does not reproduce under the live Permit2 domain separator is refused before the keeper is consulted at all, so this ERC-1271 surface will only ever endorse a genuine Permit2 digest for this Permit2 on this chain. Permit2 forwards the blob verbatim — it length-checks signatures only for EOA signers, never for contract signers (`SignatureVerification.verify`). The separator is read live, not cached: Permit2 rebuilds its own when `chainid` changes, so a construction-time copy goes stale across a fork. This also gives the `permit2DomainSeparator` immutable that was removed as dead state a real job.

**Be precise about what this does not do.** The Permit2 domain separator commits to `chainId` and Permit2's own address — **never to the owner**. Two modules behind one Permit2 on one chain rebuild an identical value, so this check does not narrow M-01 by even one case. It closes a different, smaller gap: hashes that are not Permit2 digests for this chain.

**A tempting mitigation that does not work.** The natural off-chain answer is to make the Escrow `DepositWitness.depositRequestHash` commit to the module address so the digests differ per module. It does make them differ — but it does **not** prevent the drain. The witness lives *inside* the digest, and a module never sees the digest's contents, so a digest whose witness names module A still satisfies module B's ERC-1271 check verbatim and Permit2 still moves B's tokens. Committing the module address makes the resulting deposit *recognisable* as bogus afterwards; it does not stop the transfer. Pinned by `test_IsValidSignature_ModuleBoundWitnessStillValidatesElsewhere`, which exists because this is the intuitive reading and it is wrong.

**What actually prevents it, and what is being relied on.** Two things would: a keeper that is not shared between modules, or an on-chain check of the witness contents (which requires the module to reimplement Permit2's `PermitWitnessTransferFrom` encoding, including the witness type string Escrow owns). Only the first is being relied on. **Distinct keepers per module is therefore the sole control standing between this finding and an exploit**, and it is a deployment-practice constraint rather than a property of the code: nothing in the module or the factory rejects a keeper already in use elsewhere, and `setKeeper` can reintroduce sharing at any time.

**Coverage.** `test_IsValidSignature_CrossModuleReplayIsNotPreventedOnChain` asserts the replay still succeeds, and fails loudly if an on-chain binding is ever added without this section being revised. `test_IsValidSignature_RejectsDigestNotBuiltUnderThePermit2Domain` covers the domain separator check in both directions, `test_IsValidSignature_FollowsThePermit2DomainSeparatorAcrossAFork` covers the live read, and `test_IsValidSignature_MalformedSignatureBlobFailsWithoutReverting` covers the envelope decode failing closed rather than reverting.

---

## L-03 and I-05 — divergence between the allowance and the emitted intent

These are reported separately but share one cause:

```solidity
pendingAmount[token] += amount;                              // monotonic, never decremented
IERC20(token).forceApprove(permit2, pendingAmount[token]);   // allowance follows the counter
uint256 available = IERC20(token).balanceOf(address(this));  // intent follows the balance
```

Two quantities govern one operation, and they diverge in both directions:

- after Permit2 pulls, the balance falls and the counter does not, so the allowance exceeds the funds held (**L-03**);
- after a refund or an unsolicited transfer, the balance exceeds the counter, so the keeper reads the larger figure from the event, requests it, and `transferFrom` reverts against the smaller allowance (**I-05**). One wei from any address rendered a new module unusable until the owner swept it.

**Fix.** The allowance, the emitted intent and `pendingAmount` all derive from the balance actually held, giving a checkable post-condition:

```
pendingAmount[token] == allowance(module, permit2) == balanceOf(module)
```

`pendingAmount` is consequently no longer cumulative. The interface documentation, which described the monotonic behaviour as intentional, was updated accordingly.

**Coverage.** Reverting fails both tests with the defect's own arithmetic: `1000000000 != 1000000001` and `2000000000 != 1100000000`.

---

## L-02 — refunds unreachable behind a stale allowance

The allowance was refreshable only through `execute`, which requires a positive pull from PaymentRails. A refund arriving while PaymentRails is empty was therefore visible to the keeper but could not be requested, and was recoverable only by the owner pausing and sweeping.

**Fix.** `syncAllowance(address token)` re-points the allowance at the current balance. It is gated `onlyKeeper`: raising an allowance confers nothing by itself, since Permit2 still requires a keeper signature to move funds, and the keeper is the party otherwise blocked. It is `whenNotPaused` so that it cannot contend with `returnTokenBalance`, which is `whenPaused` and deliberately revokes the allowance to zero.

---

## L-04 — route changes redirecting staged funds

**Addressed by a different mechanism than recommended.**

The report recommends emitting the newly-pulled amount rather than the total balance. That conflicts with the module's documented sweep behaviour — quoted in the report under L-02 — whereby refunds and failed deposits are intended to be collected by a later request. Both properties cannot hold simultaneously.

**Fix.** The sweep is retained and the collision is instead made impossible. `stagedRoute[token]` records the destination the current balance was pulled for, and `execute` refuses a different route while the balance is non-zero; the balance must be drained or swept before reconfiguration. The guard is keyed on the decoded destination fields rather than the raw `params` bytes, so it tracks the route rather than its encoding, and it is scoped to staged funds rather than to route changes in general, making it an ordering constraint rather than a lock. `returnTokenBalance` clears the record so it cannot outlive the funds it describes.

The original recommendation remains available as an alternative, at the cost of the refund collection described above. We would suggest that trade be made explicitly rather than by default.

---

## L-01 and I-04 — permissionless creation and deterministic front-running

**L-01.** Creation was permissionless, so any address could deploy a factory module naming another party's PaymentRails while assigning itself owner and keeper. The result satisfies `isDeployedModule` and appears in `getModulesForPaymentRails`. The factory documentation already states that the registry is informational and not an authorisation signal, which addresses whether membership implies trust, but not whether a third party can write into another party's listing. Creation now requires the caller to be the PaymentRails owner.

> **Operational consequence.** Any deployment flow whose caller is not the PaymentRails owner now requires either the owner as caller, or a deployer allowlist in place of the owner check.

**I-04.** `createDeterministic` used the caller-supplied salt directly, so an observer could deploy to the same address first and cause the legitimate deployment to revert. The salt is now `keccak256(deployer, salt)`, making each deployer's address space disjoint and removing the race rather than narrowing it.

> **This changes every deterministic address.** Any precomputed address must be recalculated. `predictDeterministicAddress` therefore takes `deployer` explicitly, since prediction is an off-chain read and the requesting party is usually not the deploying party.

---

## I-06 — sender-paid transfer fees

`_pullExactToken` measured the amount that arrived but not the amount debited. A token charging its fee to the sender therefore passed the check: the module received exactly `amount` and reported a clean transfer, while PaymentRails was debited `amount + fee`.

**Fix.** Both sides are now measured. The debit is computed with a guard rather than a bare subtraction, since a token that credits the sender within `transferFrom`, or a self-transfer, can leave the sender's balance unchanged or higher, where an underflow would revert without identifying the cause.

The existing `FeeOnTransferERC20` fixture does not exercise this case, as it reduces the amount credited to the recipient, which the received-amount check already rejected. `SenderFeeERC20` credits the recipient in full and charges the sender in addition.

---

## I-01, I-02, I-03

**I-01.** `onlyKeeper` was unused. Rather than remove it, it now gates `syncAllowance` (L-02).

**I-02.** `renounceOwnership` reverts. Every recovery path is `onlyOwner`, and the sweep is `onlyOwner whenPaused`, so renouncing while paused and holding tokens would strand the funds permanently.

**I-03.** The constructor emits `KeeperSet(address(0), keeper)`, and the factory's `AtumModuleCreated` now carries the keeper. The initial keeper authorises movement of every token the module holds and was not previously logged by either, so event history alone could not establish which key was able to sign at a given time. The keeper is not indexed on `AtumModuleCreated`, which already carries the maximum three indexed topics; it is filterable through `KeeperSet`. This changes the event signature to `AtumModuleCreated(address,address,address,address)`, so any consumer decoding it must be updated.

---

## Additional finding: `permit2DomainSeparator`

Assigned in the constructor, exposed through a getter, and read nowhere. Removed.

It was also not a value that should be cached: Permit2 rebuilds its domain separator when `chainid` changes, so a value fixed at construction becomes stale across a fork.

Removing the call would additionally have removed the rejection of a non-contract Permit2 address that it incidentally provided, since calling `DOMAIN_SEPARATOR()` on an address with no code reverts. That check is now explicit (`AtumModule_Permit2NotContract`).
