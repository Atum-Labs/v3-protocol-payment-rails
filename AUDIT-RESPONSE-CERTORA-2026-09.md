# Certora draft report — Atum Module: response and fixes

**Scope** `credit-cooperative/v3-protocol-payment-rails` @ `a5e33f361c04257d92de86d456c934528a0cc925` (PR #16)

**Report** Certora draft, September 2026 — 11 findings: 0 critical, 0 high, 1 medium, 4 low, 6 informational

**Status** All 11 addressed. No finding deferred, and none answered with an acknowledgement alone.

Three further observations raised during the fix review are answered under [Fix-review follow-on](#fix-review-follow-on-three-observations-on-the-mitigations): one fixed, two acknowledged with the reasoning recorded.

Each fix is accompanied by a regression test. `forge test`: **662 pass, 0 fail, 57 skipped** across 104 suites. `solhint`: 0 errors.

---

## Summary

| ID   | Severity | Response                                                     |
| ---- | -------- | ------------------------------------------------------------ |
| M-01 | Medium   | Fixed — EIP-712 wrap binding module address and chain id     |
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

**A key-management constraint accompanies the fix.** M-01's replay is only possible between modules that share a keeper, so modules will be issued distinct keepers. This is a deployment-time constraint on key management, **not enforced on-chain**, and it is stated here because M-01's fix requires a coordinated on-chain and off-chain deployment and so cannot be instantaneous. It reduces exposure in that interval; the fix below is what removes the finding.

Two additional observations arising from the review:

1. **L-03 and I-05 describe the same defect from opposite sides**, and are resolved by a single change.
2. **`permit2DomainSeparator` was unused state** — assigned in the constructor, exposed by a getter, and read nowhere. Removed.

---

## M-01 — cross-module signature replay (Medium)

**Mechanism.** `isValidSignature` validated the caller's raw hash directly against the keeper. The digest Permit2 constructs does not contain the owner, and Permit2 tracks nonces per owner. Two modules sharing a keeper therefore accepted the identical `(hash, signature)` pair, and one authorisation could be spent once at each.

**Key-management constraint.** The replay is only possible between modules that share a keeper, so modules will be issued distinct keepers. To be precise about its status: this is a constraint on deployment practice and is **not enforced by the contracts** — nothing in the module or the factory rejects a keeper already in use elsewhere, and `setKeeper` could reintroduce sharing after deployment. It is therefore a reduction in exposure during the interval before the fix is deployed, not a control the code guarantees. The fix below is what removes the finding.

**Fix.** The incoming hash is wrapped in the module's own EIP-712 domain before validation, binding `address(this)` and `chainid` into the signed payload. `keeperDigest(bytes32)` is exposed so the off-chain signer can compute the value it must sign.

**An interaction worth recording.** `_invalidatedPermitDigests` is keyed on the raw hash, and `invalidateDigest` is called with the Permit2 digest — the same value that reaches `isValidSignature`. The wrap changes what is validated; it deliberately does not change what is looked up. Keying that map on the wrapped digest instead would leave previously revoked digests appearing un-invalidated while the function continued to return the ERC-1271 magic value. The pairing is covered by `test_InvalidateDigest_StillBlocksAfterTheEIP712Wrap`.

**Deployment consequence.** The keeper must sign `keeperDigest(...)` rather than the bare Permit2 digest. A keeper that has not been migrated produces signatures this module rejects, halting payments for that module. The failure mode is fail-closed — no funds are at risk — but the two halves must be deployed together. Sequence: extend the keeper to the new form, deploy the module, migrate the keeper, retire the old form.

**Coverage.** Reverting to raw-hash validation fails seven tests, including `test_IsValidSignature_RejectsRawPermit2Digest` in the opposite direction, confirming that raw digests were previously accepted. `test_IsValidSignature_SignatureForOneModuleIsRejectedByAnother` asserts the exploit shape directly: a single signature over the raw digest, presented to two modules, refused by both.

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

**Fix.** The sweep is retained and the collision is instead made impossible. `stagedRoute[token]` records the destination the current balance was pulled for, and `execute` refuses a different route while the balance is non-zero; the balance must be drained or swept before reconfiguration. The guard is keyed on the decoded destination fields rather than the raw `params` bytes, so it tracks the route rather than its encoding, and it is scoped to staged funds rather than to route changes in general, making it an ordering constraint rather than a lock. `returnTokenBalance` clears the record so it cannot outlive the funds it describes. `validate` applies the same guard, so a preview cannot report success for a call `execute` would refuse — see the fix-review follow-on below.

The original recommendation remains available as an alternative, at the cost of the refund collection described above. We would suggest that trade be made explicitly rather than by default.

**The guard's scope, stated narrowly.** It closes exactly one thing: a PaymentRails reconfiguration silently redirecting a balance the module is holding and has not yet released. It is not settlement attribution and does not make the module request-scoped. It treats a zero balance as settlement, which a refund can falsify. The residual cases are enumerated under the follow-on below and documented on `IAtumModule.stagedRoute`.

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

## Fix-review follow-on (three observations on the mitigations)

Raised against the fixes above rather than against the original code. Each was reproduced before being answered.

### 1. `validate` and `estimateOutput` did not apply the L-04 route guard — fixed

Confirmed. With Route A funds staged and PaymentRails reconfigured to Route B, `validate` returned `(true, "")` while `execute` in the same state returned `"Route changed while funds are staged"`.

**Severity is bounded by where `validate` sits.** It is not on the settlement path. `PaymentRails.executeAction` calls `execute` directly and never consults `validate`; the only production caller is `previewExecution`, a `view`. `IActionModule` states this explicitly. So `validate` returning `true` authorises nothing, and the failure is soft — `execute` returns a failed result, PaymentRails emits `ActionFailed`, revokes the approval and returns `false`, with nothing pulled and no state changed. The cost is a wasted transaction.

**Fix.** `execute` and `validate` share `_routeChangedWhileStaged(token, paymentParams)`. Both evaluate it before any pull, so they read identical `stagedRoute` and `balanceOf` values and cannot disagree within a block — the mirror is exact rather than approximate.

> **Consequence.** `previewExecution` does `revert(reason)` on a failed `validate`, so the preview now reverts with `"Route changed while funds are staged"` where it previously returned `(0, token)`.

**`estimateOutput` is deliberately not changed.** It is a constant function: every path returns `(0, token)`, including paused and invalid params. The module produces no on-chain output token, since settlement occurs off-chain through Escrow, so there is no estimate for a route change to alter and the guard would change no return value. That `estimateOutput` cannot distinguish success from failure is a real observation, but it is an `IActionModule` interface property rather than anything specific to this guard.

For completeness, `validate` remains a deliberately imperfect model of `execute`: `previewExecution` passes the rails' full balance while `executeAction` takes a caller-supplied `amount`, and `_hasSufficientBalance` reads `balanceOf(msg.sender)`, so `validate` is only meaningful when PaymentRails is the caller. The route guard is the one divergence that is cheap and exact to close.

**Coverage.** Reverting fails `test_Validate_WhenRouteChangedWhileFundsAreStaged_ReturnsRouteChanged` with the defect's own signature (`true != false`) and `test_PreviewExecution_WhenRouteChangedWhileFundsAreStaged_Reverts`. Two negative controls pin that the mirror does not over-fire.

### 2. Route changes, refunds and recovery — acknowledged, documented, not fixed

Confirmed, including all three paths described. The mechanism is that **`stagedRoute[token]` is cleared only by `returnTokenBalance`, never by settlement**, because the module receives no notification of a Permit2 pull. After Escrow drains the balance the record still names the old route while the balance is zero, so the guard's `balanceOf > 0` term lets the next route stage over it. A later refund then merges into one fungible balance and is swept under the new route — via `syncAllowance`, via a further `execute`, or after a sweep and unpause.

**A fourth case, which the fix introduced and which we would rather record than omit: the guard also refuses the corrective change.** Once a refund for the old route sits under the new route's record, pointing PaymentRails back at the old route fails the guard as well, because the balance is non-zero and the routes differ. The on-chain exit is pause + `returnTokenBalance`, which returns funds to PaymentRails rather than paying them to the intended beneficiary.

This follows from the module being balance-scoped rather than request-scoped, which is explicit in its documentation: no request ids, no per-payment reservation, no recovery metadata. Destination selection has never been a module invariant. `AtumIntentCreated` is a signal, the keeper constructs the Permit2 request off-chain, and `syncAllowance` deliberately does not stage a route. Attributing a refund to the request that produced it is keeper work, and the keeper holds the request ids and Escrow events required.

**Blast radius is single-tenant.** One module is bound to one immutable PaymentRails, there is one config per (rails, token), and route changes are `onlyOwner` on PaymentRails. Both routes are therefore destinations chosen by the same operator — misallocation within one operator's control, not cross-user theft. `executeAction` is permissionless to call, but the caller cannot choose a destination.

Documented on `IAtumModule.stagedRoute` and the module header, and pinned by `test_ExecuteAction_RefundOfAnOldRouteIsSweptUnderTheNewOne` and `test_ExecuteAction_GuardAlsoRefusesTheCorrectiveRouteChange`.

> **Open with the auditor.** Whether an `onlyOwner clearStagedRoute(address token)` emitting an event would be accepted, so that a deliberate redirect is explicit and logged rather than requiring a pause and a full sweep. L-04's requirement is that a route change must not *silently* redirect staged funds; an authorised, logged override appears consistent with that.

### 3. `_checkPaymentRailsOwner` does not verify that `paymentRails` is a PaymentRails — acknowledged

The conclusion is correct. One correction to the mechanism, because it affects reproducibility.

**A contract whose `owner()` returns `msg.sender` does not satisfy the check.** `Ownable(paymentRails).owner()` is called by the *factory*, so `msg.sender` inside the callee is the factory address; the comparison then evaluates caller-versus-factory and reverts with `AtumModuleFactory_NotPaymentRailsOwner`. The shape that works is a contract returning a hardcoded caller-controlled address. Verified in both directions.

The check is an authorisation check over registry writes, not a type assertion, and was scoped to L-01 only. Its impact is bounded by the same quirk: because `owner()` must return `msg.sender`, a caller can only register against a contract that names them, and cannot write into another party's listing. What remains is entries under addresses they already control — registry noise, on top of the unbounded `_deployedModules` growth already documented.

**No type probe will be added.** The factory is not a trust root: `new AtumModule(permit2, anyRails, attacker, attacker)` bypasses it entirely, so no check here can establish a property about modules in general. And every available probe — ERC-165, calling `getTokenConfig`, any marker function — is a shape check, equally forgeable by the contract being probed. Adding one would turn an informational registry into one that looks authoritative and is not. `PaymentRails.configureToken` already probes `IActionModule.moduleType()` in a `try`/`catch` and is likewise a sanity check rather than proof.

The factory NatSpec now states that the owner check gates who may write and asserts nothing about what `paymentRails` is.

---

## Additional finding: `permit2DomainSeparator`

Assigned in the constructor, exposed through a getter, and read nowhere. Removed.

It was also not a value that should be cached: Permit2 rebuilds its domain separator when `chainid` changes, so a value fixed at construction becomes stale across a fork.

Removing the call would additionally have removed the rejection of a non-contract Permit2 address that it incidentally provided, since calling `DOMAIN_SEPARATOR()` on an address with no code reverts. That check is now explicit (`AtumModule_Permit2NotContract`).
