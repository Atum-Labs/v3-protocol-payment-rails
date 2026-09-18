# Integration constraint: the Atum gateway's sender-auth check assumes an EOA

**Status** Open. Not fixable in this repository.

**Raised by** Certora, alongside the September 2026 draft report, explicitly as outside the audit's scope.

**Owner** The off-chain payment gateway and settler, not `AtumModule`.

`AtumModule` is a smart-contract wallet. It holds the source tokens and authorizes Permit2 transfers through ERC-1271, with a keeper as the signing key. The standard Atum gateway validates an EVM sender by `ecrecover`ing the sender-auth signature and requiring the recovered address to equal `PaymentRequest.source.account`. A contract wallet has no EOA to recover to, so **every standard `AtumModule` payment is rejected before it reaches the chain**.

This is a functional blocker rather than a security defect, and it is not one of the 11 audit findings.

## The deadlock

```
PaymentRails.executeAction(token, 100)
  -> module holds 100, Permit2 allowance 100
  -> keeper builds a PaymentRequest and signs the Permit2 authorization
```

| | |
| --- | --- |
| Signed by | `keeper` |
| Token owner / Permit2 owner | `AtumModule` |
| `source.account` | `AtumModule` |
| Recovered ECDSA signer | `keeper` |
| Gateway requires | recovered signer `== source.account` |

`keeper != AtumModule`, so the request is rejected.

**Setting `source.account = keeper` does not help.** Escrow's deposit uses the depositor as the Permit2 owner, so Permit2 would attempt to pull from the keeper, which holds no tokens and has granted no allowance. One assignment satisfies the recovery check and breaks the pull; the other satisfies the pull and breaks the recovery check. No module-side value satisfies both.

## The on-chain path is already correct

Worth separating, because it narrows the fix considerably:

- **On-chain**, Permit2 calls `isValidSignature` on the module, the module validates against its keeper, and the transfer succeeds. This works today.
- **Off-chain**, the gateway and settler perform an `ecrecover` pre-check before the deposit is ever submitted. This is what rejects the request.

The failure is entirely in the off-chain validation layer. No on-chain change is required.

## Referenced locations

In `protocol-main` (paths as reported):

- `payment-gateway-client/src/index.ts:505` — sets `source.account` from the depositor value
- `schemas/declarations/PaymentRequest/v1/bindings/go/sender-auth/senderauth/evm.go:108`
- `schemas/declarations/PaymentRequest/v1/bindings/typescript/sender-auth/src/adapters/evm.ts:176`
- `contracts/evm/source/src/Escrow.sol:318` — deposit uses the depositor as the Permit2 owner
- `schemas/apis/settler-gateway/v1/session-stream/README.md:386` — the settler repeats the same recovery before depositing

## Proposed fix, off-chain

When `source.account` has code, validate the sender auth with an ERC-1271 `isValidSignature(hash, signature)` call against `source.account` instead of `ecrecover`, accepting the call when it returns `0x1626ba7e`.

`AtumModule` already exposes exactly this surface, and the caller passes the **raw Permit2 digest** — the module applies its own EIP-712 wrap internally, so the gateway needs no knowledge of the module's digest construction.

The branch is needed in at least three places: the Go binding, the TypeScript binding, and the settler's pre-deposit check.

## This is not specific to this module

`Atum-Labs/erc1271-payment-sender` ("Send Atum Payments From Your Smart Contract") is Atum's own published pattern for contract senders, and it has the same shape: the module contract holds the tokens and is the payment source, while the signature recovers to a separate EOA.

From its documentation:

> The payment source account must be the module contract address.

> The signature must recover to the current `owner()` of `AtumModule`, unless the owner is a contract wallet with its own ERC-1271 validation path.

So the recovered signer is the owner EOA while `source.account` is the module — the same mismatch described above, with `owner` in place of `keeper`.

Two possibilities, and they should be distinguished before any fix is designed:

1. The gateway already has an ERC-1271 path and the reported `ecrecover` check is on a code path that contract senders do not take, in which case the finding may be narrower than it appears.
2. The reported check is the live one, in which case the published contract-sender pattern is affected too and the fix is broader than this module.

This has not been confirmed either way from this repository.

## Interaction with the M-01 fix — read before fixing

The M-01 remediation binds the keeper's signature to the module via EIP-712 to stop a cross-module replay, so the keeper signs `keeperDigest(permit2Digest)` rather than the bare Permit2 digest:

```solidity
function keeperDigest(bytes32 permit2Digest) public view override returns (bytes32) {
    return _hashTypedDataV4(keccak256(abi.encode(KEEPER_APPROVAL_TYPEHASH, permit2Digest)));
}
```

Consequences:

1. **Before M-01**, `ecrecover(permit2Digest, signature)` returned the keeper, and the only failure was the address comparison. **After M-01** it returns an unrelated address — the keeper is no longer recoverable from the raw digest at all.
2. Any fix that recovers a signer and compares it to a **configured keeper address** must therefore recover over `keeperDigest(...)`, not the raw Permit2 digest.
3. **The ERC-1271 fix above is unaffected by M-01** and behaves identically before and after it, because the module applies the wrap internally. This is the main reason to prefer it over any recovery-based workaround.
