# Certora draft report — Atum Module: response and fixes

**Scope** `credit-cooperative/v3-protocol-payment-rails` @ `a5e33f361c04257d92de86d456c934528a0cc925` (PR #16)

**Report** Certora draft, September 2026 — 11 findings: 0 critical, 0 high, 1 medium, 4 low, 6 informational

**Status** All 11 addressed. **M-01, the sole Medium, is answered differently from the report's recommendation**: the replay is prevented by the Atum Escrow integration rather than by a digest binding in the module, which is the case the report's own Impact paragraph anticipates. The M-01 section sets out the four links and what they rest on.

Three further observations raised during the fix review are answered under [Fix-review follow-on](#fix-review-follow-on-three-observations-on-the-mitigations): one fixed, two acknowledged with the reasoning recorded.

Each fix is accompanied by a regression test. `forge test`: **664 pass, 0 fail, 57 skipped** across 104 suites. `solhint`: 0 errors.

---

## Summary

| ID   | Severity | Response                                                     |
| ---- | -------- | ------------------------------------------------------------ |
| M-01 | Medium   | Fixed — by the Escrow integration + ERC-1271 caller allowlist |
| L-01 | Low      | Fixed — creation restricted to the PaymentRails owner        |
| L-02 | Low      | Fixed — `syncAllowance`, keeper-gated                        |
| L-03 | Low      | Fixed — addressed together with I-05                         |
| L-04 | Low      | Acknowledged — a config change cannot redirect a currently-held balance; a later refund can be paid to the new route, and that is accepted |
| I-01 | Info     | Resolved by giving the unused modifier a caller              |
| I-02 | Info     | Fixed — `renounceOwnership` reverts                          |
| I-03 | Info     | Fixed — initial keeper emitted by the module and the factory |
| I-04 | Info     | Fixed — CREATE2 salt bound to the caller                     |
| I-05 | Info     | Fixed — addressed together with L-03                         |
| I-06 | Info     | Fixed — sender debit now checked                             |

**A key-management constraint accompanies M-01 as defence in depth.** The replay is only constructible between modules that share a keeper, so modules are to be issued distinct keepers. This is a deployment-time constraint on key management, **not enforced on-chain**. It is not what prevents the finding — see M-01 below for what does — but it is the layer that survives if that argument's assumptions are ever violated.

Two additional observations arising from the review:

1. **L-03 and I-05 describe the same defect from opposite sides**, and are resolved by a single change.
2. **`permit2DomainSeparator` was unused state** — assigned in the constructor, exposed by a getter, and read nowhere. Removed.

---

## M-01 — cross-module signature replay (Medium)

**Status: the replay is prevented, by the integrating protocol rather than by a digest binding in this module.** This is the case the report's own Impact paragraph anticipates — *"Exact impact depends on the integrating protocol and whether its digest independently binds the module address."* Atum Escrow binds it, not inside the Permit2 digest but as an independently-signed precondition that must pass before Permit2 is called at all. The recommended EIP-712 wrap was implemented, found to be incompatible with the keeper's authorisation model, and withdrawn; what ships in this module is a restriction on which applications can reach its ERC-1271 surface, which is what makes the Escrow argument sound rather than incidental.

**Mechanism.** `isValidSignature` validated the caller's raw hash directly against the keeper. The digest Permit2 constructs does not contain the owner, and Permit2 tracks nonces per owner. Two modules sharing a keeper therefore accepted the identical `(hash, signature)` pair, and one authorisation could be spent once at each.

**Why the replay cannot be carried out against this integration.** Four links, each verifiable in deployed code:

1. **Permit2 binds the spender to the caller.** `PermitHash.hashWithWitness` puts `msg.sender` into the signed struct, so only the contract named as spender can present the signature at all. The keeper's signing policy independently pins `message['spender']` to an allowlisted Escrow, so no other spender is ever signed for.
2. **This module answers only Permit2.** `isAuthorizedSignatureCaller` is seeded with Permit2 at construction, so there is no second route to the ERC-1271 surface.
3. **Escrow derives `depositId` from the depositor** — `keccak256(abi.encode(depositor, depositSignature, permit.nonce))` — and requires it to equal `reserveWitness.depositId`. Replaying a deposit signature against a second module changes `depositor`, so it changes `depositId`, so the attacker must supply a reserve witness carrying the new value.
4. **That reserve witness must be signed by the reserver**, and `reserver` is a member of the *deposit* witness, so it cannot be swapped without invalidating the very signature being replayed. The attacker therefore needs the legitimate reserver to sign a `ReserveWitness` whose `depositId` commits to the victim module.

Escrow verifies the reserve signature *before* calling Permit2 — deliberately, so the external call happens last — so a replayed deposit reverts `DepositNotFound` before this module's `isValidSignature` is ever reached. Both `deposit()` and `depositMany()` route through the same `_deposit`, so neither path is exempt.

**What this rests on, stated plainly.** That the reserver is an independent party from the keeper, and that it signs only `depositId` values it can attribute to a deposit authorisation it actually issued. A reserver that blind-signs an arbitrary `depositId`, or a reserver key held alongside the keeper key, removes the protection. This is a property of the composed system — Permit2, Escrow, the reserver role and this module together — not of any one contract.

**Why the keeper's signing policy cannot substitute for the reserver.** It is tempting to treat the keeper's policy engine as the control, since it refuses to sign anything whose spender, token, reserver, releaser or destination is not allowlisted. It cannot cover this case, for the same structural reason the finding exists: **Permit2's signed struct has no owner field, so the policy cannot bind which module a signature is for.** Concretely, an attacker with keeper signing access obtains a signature for a digest describing a deposit from a module they control — the policy permits it, every bound field is legitimate — and then submits it with `depositor` set to a funded module instead. Every check in the keeper's policy passes. Link 4 is what fails: the `depositId` changes with the depositor, and the attacker has no reserver signature over the new one. **Separating the reserver key from the keeper key is therefore a requirement, not hygiene.**

**Coupling to the out-of-scope gateway item (#13).** The four links above describe the standard Escrow deposit flow with `depositor = AtumModule`, which is precisely the flow #13 reports as currently blocked: the gateway `ecrecover`s the sender-auth signature and requires the recovered address to equal `source.account`, which no contract wallet satisfies. **Whatever unblocks #13 must be re-checked against this argument.** In particular #13 notes that setting `source.account = keeper` does not work because Permit2 would then pull from the keeper; it would also void the protection described here, because the Permit2 owner would become an EOA and the `depositId` binding would commit to a different party. 
**The four links are executed, not merely read.** The contract-depositor path previously had no coverage on the Escrow side — every deposit-flow test there uses an EOA depositor, where Permit2's own `ecrecover` binds the owner and the finding cannot arise, so the one case where it *can* arise was untested. `test/Escrow.contractDepositorReplay.t.sol` in the Escrow repository now runs it against real Permit2 with two ERC-1271 wallets sharing a keeper:

| Test | Asserts |
| --- | --- |
| `test_bothWalletsValidateTheSameKeeperSignature` | the precondition is real — one keeper signature satisfies both ERC-1271 surfaces |
| `test_replayAgainstAnotherWallet_revertsDepositNotFound` | the verbatim replay is refused before Permit2 is reached |
| `test_replayWithRecomputedDepositId_revertsInvalidSignature` | recomputing `depositId` for the victim fails for want of a reserver signature |
| `test_afterASucceeds_replayToBStillNeedsAReserverSignature` | the per-owner nonce is still free after a legitimate deposit, and still unspendable |
| `test_depositForTheIntendedWallet_succeeds` | the control — the same authorisation works for the wallet it was issued for |

Both replay cases also assert the victim's balance is unchanged.

**Why the recommended EIP-712 wrap was withdrawn.** It was implemented and it worked, binding `address(this)` and `chainid` into the signed payload. It is not shipped because it is incompatible with how the keeper authorises payments. The keeper is a policy-gated signer whose policy inspects the `PermitWitnessTransferFrom` struct — spender, permitted token and amount, and the witness members that carry the payout instruction — and refuses to release a signature for anything that does not match an expected payment. Wrapping makes the only thing the keeper ever signs an opaque `bytes32`, leaving that policy nothing to read; in the deployed configuration the wrapped payload matches no allow rule at all and simply cannot be signed. Trading an enforced authorisation policy for an on-chain replay binding is not a clear net gain, and not a trade to make silently.

**What the module enforces instead: who may ask.** `isValidSignature` answers only callers in `isAuthorizedSignatureCaller`, seeded with Permit2 at construction and otherwise an explicit owner decision through `setSignatureCaller`. This is aimed squarely at the report's own generalisation — *"The problem is not specific to Permit2; Permit2 is one confirmed exploitation path."* A keeper signature was a bearer token at every ERC-1271 surface treating this module as a signer; it is now confined to applications that were deliberately trusted, which turns an open-ended exposure into a bounded one.

**Why nothing more is enforceable at this layer.** ERC-1271 supplies a 32-byte keccak output and no preimage. The domain the digest was built under, the spender it names, the amount it moves and the witness it carries are all unreachable from inside the module. Any check the module could make about the digest's *contents* would either require the caller to supply the preimage — which the caller is the attacker in the replay scenario — or re-derive what the constructing application already guarantees. Permit2 builds the digest under its own domain separator and cannot present anything else; Escrow fixes the witness. Re-deriving either inside the module checks those contracts against themselves.

**Be precise about what the allowlist does and does not do.** In isolation it does not narrow the reported replay: two modules sharing a keeper sit behind the *same* Permit2 — there is one per chain — so both authorise it and both would validate the identical `(hash, signature)` pair if asked. Its role is to guarantee that Permit2, and therefore Escrow, is the *only* application that can ask. Without it, the four-link argument above covers one integration while a keeper signature stays a bearer token everywhere else.

**Consequences for authorising a second caller.** `setSignatureCaller` extends the same trust to another application, and the argument above does not transfer with it. Any application authorised here must independently bind the module address somewhere in its own flow, as Escrow does through `depositId`. The NatSpec on `setSignatureCaller` says so.

**Defence in depth: distinct keepers.** The replay is only constructible between modules sharing a keeper, so modules are still to be issued distinct keepers. It is no longer the sole control, but it is worth keeping: it is the layer that survives if the reserver assumption above is ever violated. It remains **not enforced on-chain** — nothing in the module or the factory rejects a keeper already in use, and `setKeeper` can reintroduce sharing.

**A mitigation that does not work, recorded because it is the intuitive one.** Making the Escrow `depositRequestHash` commit to the module address is not sufficient on its own, and should not be mistaken for the protection described above. The witness lives inside the digest and a module cannot see the digest's contents, so a digest whose witness names module A still satisfies module B's ERC-1271 check verbatim. What blocks the replay is the `depositId` equality check against an independently signed reserve witness, not the contents of the deposit witness.

**Coverage.** `test_IsValidSignature_RejectsUnauthorizedCallers` covers the allowlist, including `address(0)`, the keeper and the owner. `test_Constructor_AuthorizesPermit2AndEmitsIt` pins the seeded entry and its log. `test_SetSignatureCaller_OwnerCanAuthorizeAndRevoke` covers both directions and that revocation leaves Permit2 intact. `test_IsValidSignature_CrossModuleReplayIsNotPreventedByTheModuleAlone` records the division of responsibility — the module validates the keeper, not the digest's contents — and fails loudly if an on-chain binding is ever added without this section being revised.

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

**Fix.** The sweep is retained. A reconfiguration cannot redirect a balance the module currently holds: `stagedRoute[token]` records the destination that balance was pulled for, and `execute` refuses a different route while the balance is non-zero; the balance must be drained or swept before reconfiguration. The guard is keyed on the decoded destination fields rather than the raw `params` bytes, so it tracks the route rather than its encoding, and it is scoped to staged funds rather than to route changes in general, making it an ordering constraint rather than a lock. `returnTokenBalance` clears the record so it cannot outlive the funds it describes. `validate` applies the same guard, so a preview cannot report success for a call `execute` would refuse — see the fix-review follow-on below.

The original recommendation remains available as an alternative, at the cost of the refund collection described above. We would suggest that trade be made explicitly rather than by default.

**Acknowledged, both halves.** A config change cannot redirect a balance this module currently holds. A later refund can be paid to the new route, and that is accepted. It is not settlement attribution and does not make the module request-scoped. It treats a zero balance as settlement, which a refund can falsify. That refund path, and the corrective-change case it produces, are enumerated under the follow-on below and documented on `IAtumModule.stagedRoute`.

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

**I-02.** `renounceOwnership` reverts. Every recovery path is `onlyOwner`, and the sweep is `onlyOwner whenPaused`, so renouncing while paused and holding tokens would strand the funds permanently. The M-01 response strengthens this: `setSignatureCaller` is also `onlyOwner`, so renouncing would additionally freeze the ERC-1271 caller set at whatever it happened to hold, with no way to revoke an application later found to be unsafe.

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

> **Raised with the auditor and closed.** We asked whether an `onlyOwner clearStagedRoute(address token)` emitting an event would be accepted, so that a deliberate redirect is explicit and logged rather than requiring a pause and a full sweep. Declined, and we agree with the reasoning: because refunds can land unexpectedly and be picked up by `syncAllowance`, clearing the record would not address the underlying behaviour. The finding is recorded as acknowledged with both halves: a config change cannot redirect a balance this module currently holds; a later refund can be paid to the new route, and that is accepted. No function was added.

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
