# Certora draft report — Atum Module: response and fixes

**Scope** `credit-cooperative/v3-protocol-payment-rails` @ `a5e33f361c04257d92de86d456c934528a0cc925` (PR #16)
**Report** Certora draft, September 2026 — 11 findings: 0 critical, 0 high, 1 medium, 4 low, 6 informational
**Status** all 11 addressed. No finding deferred, none answered "acknowledged" only.

Every fix carries a regression test, and every test was **revert-verified**: the production change is
restored in a form that still compiles, the test is confirmed to fail, and the fix is reinstated. A test
that cannot fail proves nothing, and the compile constraint is what stops the revert from being vacuous.

`forge test`: **668 pass, 0 fail, 57 skipped** across 104 suites. `solhint`: 0 errors.

---

## Summary

| ID   | Severity | Response                                                         |
| ---- | -------- | ---------------------------------------------------------------- |
| M-01 | Medium   | Fixed — EIP-712 wrap binding module address + chainid            |
| L-01 | Low      | Fixed — creation restricted to the PaymentRails owner            |
| L-02 | Low      | Fixed — `syncAllowance`, keeper-gated                            |
| L-03 | Low      | Fixed — unified with I-05                                        |
| L-04 | Low      | Fixed — **by a different mechanism than recommended**; see below |
| I-01 | Info     | Resolved by giving the modifier a caller, not by deleting it     |
| I-02 | Info     | Fixed — `renounceOwnership` reverts                              |
| I-03 | Info     | Fixed — initial keeper emitted                                   |
| I-04 | Info     | Fixed — CREATE2 salt bound to the caller                         |
| I-05 | Info     | Fixed — unified with L-03                                        |
| I-06 | Info     | Fixed — sender debit now checked                                 |

Two observations that changed the shape of the work, neither of which is in the report:

1. **L-03 and I-05 are one defect observed from opposite sides**, and close with a single change.
2. **`permit2DomainSeparator` was dead state** — captured in the constructor, exposed by a getter, read
   nowhere. Removed.

---

## M-01 — cross-module signature replay (Medium)

**Mechanism.** `isValidSignature` validated the caller's raw hash directly against the keeper. The digest
Permit2 constructs does not contain the owner, and Permit2 tracks nonces **per owner**. Two modules sharing
a keeper therefore accepted the identical `(hash, signature)` pair, and one authorisation could be spent
once at each — one signature, two drains.

**Fix.** The incoming hash is wrapped in the module's own EIP-712 domain before validation, binding
`address(this)` and `chainid` into the signed payload. `keeperDigest(bytes32)` is exposed so the off-chain
signer can compute the value it must sign.

**A trap inside the fix, not present in the report.** `_invalidatedPermitDigests` is keyed on the **raw**
hash, and `invalidateDigest` is called by the keeper with the Permit2 digest — the same value that arrives
at `isValidSignature`. The wrap changes what is _validated_; it must not change what is _looked up_.
Re-keying that map to the wrapped digest would leave every previously revoked digest appearing
un-invalidated while the function still returned the magic value: a kill-switch that reports success and
does nothing, undetectable until exploited. Pinned by `test_InvalidateDigest_StillBlocksAfterTheEIP712Wrap`.

**Deployment consequence.** The keeper must sign `keeperDigest(...)`, not the bare Permit2 digest. A keeper
that has not been cut over produces signatures this module rejects, halting payments for it. This is
**fail-closed**, which is the correct direction, but the two halves must ship together. Sequence: teach the
keeper the new form → deploy the module → cut the keeper over → retire the old form.

**Compensating control, available now, no code.** The replay requires modules to **share** a keeper.
Issuing a distinct keeper per module eliminates it immediately, independently of this deployment.

**Verification.** Restoring raw-hash validation fails seven tests, including
`test_IsValidSignature_RejectsRawPermit2Digest` in the _opposite_ direction — magic value where failure is
expected — which is direct evidence raw digests were previously accepted. The replay test asserts the exact
exploit shape: one signature over the raw digest, offered to two modules, refused by both.

---

## L-03 + I-05 — the allowance/intent divergence (unified)

The report treats these separately. They are the same defect:

```solidity
pendingAmount[token] += amount;                              // monotonic, never decremented
IERC20(token).forceApprove(permit2, pendingAmount[token]);   // allowance follows the COUNTER
uint256 available = IERC20(token).balanceOf(address(this));  // intent follows the BALANCE
```

Two quantities govern one operation, and they diverge in **both** directions:

- after Permit2 pulls, the balance falls and the counter does not → the allowance exceeds the funds held (**L-03**);
- after a refund or a donation, the balance exceeds the counter → the keeper reads the larger figure from the
  event, requests it, and `transferFrom` reverts against the smaller allowance (**I-05**). One wei from any
  address bricked a fresh module until an owner swept it.

**Fix.** Allowance, emitted intent and `pendingAmount` all derive from the balance actually held, yielding a
checkable post-condition:

```
pendingAmount[token] == allowance(module, permit2) == balanceOf(module)
```

`pendingAmount` consequently stops being cumulative; the interface NatSpec, which documented the monotonic
behaviour as intentional, was updated with it.

**Verification.** Reverting fails both tests with the defect's own arithmetic: `1000000000 != 1000000001`
(the one-wei brick) and `2000000000 != 1100000000` (the counter outrunning the balance).

---

## L-02 — refunds unreachable behind a stale allowance

The allowance was refreshable only through `execute`, which requires a positive pull from PaymentRails. An
Escrow refund arriving while PaymentRails is empty was therefore visible to the keeper and un-requestable,
recoverable only by the owner pausing and sweeping — an owner-gated incident for a routine refund.

**Fix.** `syncAllowance(address token)` re-points the allowance at the current balance. Gated `onlyKeeper`:
raising an allowance confers nothing by itself, since Permit2 still requires a keeper signature to move
funds, but the keeper is the blocked party and the narrower gate is the cheaper claim to defend.
`whenNotPaused`, so it cannot contend with `returnTokenBalance`, which is `whenPaused` and deliberately
revokes to zero.

---

## L-04 — route changes redirecting staged funds

**Fixed by a different mechanism than recommended, deliberately.**

Certora recommends emitting the newly-pulled amount rather than the total balance. That contradicts the
module's documented sweep behaviour — which the report itself quotes under L-02 — where refunds and failed
deposits are intended to be collected by a later request. Both properties cannot hold simultaneously.

**Fix.** Retain the sweep; make the collision impossible. `stagedRoute[token]` records the destination the
current balance was pulled for, and `execute` refuses a _different_ route while the balance is non-zero.
Drain or sweep first, then reconfigure. The guard is keyed on the decoded destination triple rather than the
raw `params` bytes, so it tracks the route and not its encoding, and it is scoped to staged funds rather
than to route changes as such — an ordering constraint, not a permanent lock. `returnTokenBalance` clears
it so the record cannot outlive the funds it described.

Certora's original recommendation remains available as an alternative, at the cost of the refund pickup
described above. That trade should be made explicitly rather than by default.

---

## L-01 + I-04 — permissionless creation and deterministic front-running

**L-01.** Creation was permissionless, so any address could deploy a genuine factory module naming a
victim's PaymentRails while assigning itself owner and keeper. The result satisfies `isDeployedModule` and
appears in `getModulesForPaymentRails(victim)`. The factory NatSpec already states the registry is
informational and not an authorisation signal — a fair answer to _"is membership trust?"_, but not to
_"can a stranger write into my listing?"_. Creation now requires the caller to be the PaymentRails owner.

> **Operational consequence.** Any deployment flow whose caller is not the PaymentRails owner now requires
> either the owner as caller or a deployer allowlist in place of the owner check. **51 existing test call
> sites assumed permissionless creation**, which suggests the open model may have been intentional; if so,
> an allowlist is the more appropriate shape.

**I-04.** `createDeterministic` used the caller-supplied salt directly, so a front-runner could observe the
mempool and occupy the address first, reverting the legitimate deployment. The salt is now
`keccak256(deployer, salt)`, making each deployer's address space disjoint — the race is removed rather than
narrowed.

> **This changes every deterministic address.** Anything that precomputed one must recalculate.
> `predictDeterministicAddress` therefore takes `deployer` explicitly: prediction is an off-chain read and
> the party asking is usually not the party deploying, so `msg.sender` would have been the wrong source.

---

## I-06 — sender-paid transfer fees

`_pullExactToken` measured what **arrived** and not what was **debited**. A token charging its fee to the
sender therefore passed: the module received exactly `amount`, reported a clean transfer, and PaymentRails
was down `amount + fee`. The module's "exact transfer" guarantee held in one direction only.

**Fix.** Both sides are measured. The debit is computed with a guard rather than a bare subtraction, since a
token that mints to the sender inside `transferFrom`, or a self-transfer, can leave the sender's balance
level or higher — an underflow would revert opaquely rather than naming the fault.

The existing `FeeOnTransferERC20` mock does **not** cover this: it shorts the recipient, which the
received-amount check already caught. `SenderFeeERC20` credits the recipient in full and charges the sender
on top, which is the shape that passed.

---

## I-01, I-02, I-03

**I-01.** `onlyKeeper` was dead code. Rather than delete it, it now gates `syncAllowance` (L-02) — the
finding and the fix resolve each other.

**I-02.** `renounceOwnership` reverts. Every recovery path is `onlyOwner`, and the sweep is
`onlyOwner whenPaused`, so renouncing while paused and holding tokens strands the funds permanently.

**I-03.** The constructor emits `KeeperSet(address(0), keeper)`. The initial keeper authorises moving every
token the module holds and was previously never logged, so logs alone could not reconstruct who was able to
sign at a given time — precisely the question incident response asks.

---

## Not in the report: `permit2DomainSeparator`

Captured in the constructor, exposed through a getter, read nowhere. Removed.

It was also the wrong value to cache: **Permit2 rebuilds its domain separator when `chainid` changes**, so a
value fixed at construction goes stale across a fork. Had anything begun reading it, that would have been a
live defect.

Deleting the call would additionally have removed the EOA rejection it incidentally provided — calling
`DOMAIN_SEPARATOR()` on an address with no code reverts. That check is now explicit
(`AtumModule_Permit2NotContract`), so the guarantee survives the deletion rather than disappearing with it.

---
