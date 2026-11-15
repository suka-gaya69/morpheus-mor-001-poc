# MOR-001 — Provider approval not bound to user (LumerinDiamond / SessionRouter)

Foundry PoC against deployed bytecode on a pinned Base fork. No privileged
accounts are used anywhere (`deal` funds fresh test EOAs; no prank as owner,
admin, or multisig).

## Run (one command, from a clean clone + an RPC URL)

Requires Foundry (`forge`). Clone with submodules, then run the one
command:

```sh
git clone --recursive https://github.com/suka-gaya69/morpheus-mor-001-poc.git
cd MOR-001-approval-user-binding
BASE_RPC_URL=https://mainnet.base.org forge test
```

(`forge-std` is a git submodule at `lib/forge-std`; a plain clone needs
`git submodule update --init` first.) Fork block is pinned in the tests: **57723502**
(Base). Any Base RPC URL works in place of `mainnet.base.org`.

## Tests

| Test | Result |
|---|---|
| `ApprovalUserBindingTest.testStolenApprovalOpensAttackerSessionAndDrainsFundingAccount` | PASS — attacker opens a session with a provider approval issued for a different user; victim's open reverts `SessionDuplicateApproval`; fundingAccount loses exactly 292.14 MOR |
| `DiamondAccessControlTest.testStrangerCannotReinitializeOrCut` | PASS — coverage: stranger cannot re-initialize any facet/diamond or `diamondCut`; config unchanged; diamond still functional |
| `DiamondAccessControlTest.testDelegationThroughLiveRegistry` | PASS — coverage: delegation via the live registry follows documented semantics |

## Observed output (2026-11-15, forge 1.9.0, block 57723502)

```
[PASS] testStolenApprovalOpensAttackerSessionAndDrainsFundingAccount() (gas: 39997776)
Logs:
  stolen-session provider reward (wei): 292140000000000000000
  session duration (s): 29214
  fundingAccount loss (wei): 292140000000000000000
[PASS] testDelegationThroughLiveRegistry() (gas: 2201694)
[PASS] testStrangerCannotReinitializeOrCut() (gas: 673029)
3 tests passed, 0 failed, 0 skipped
```

## What the exploit test proves

1. Provider signs approval `(bidId, chainId=8453, victim, timestamp)` — the
   exact format the provider node produces (`InitiateSessionResponse`).
2. Attacker calls `openSession(attacker, 100_000 MOR, false, approval, sig)`.
   It SUCCEEDS even though the approval names the victim.
3. Victim's identical call reverts `SessionDuplicateApproval` — the approval
   was consumed by the attacker.
4. After warping to `endsAt` and closing with a dispute receipt, the
   fundingAccount (`0x5160C0311A95E0A1072FA85Df23712A7BA1cD4b1`) pays
   292.14 MOR to the provider: `(endsAt - openedAt) * pricePerSecond` =
   `29214s * 1e16 wei/s`. Assertions check fundingAccount loss ==
   provider gain == expected reward, and that the attacker's 100,000 MOR
   stake is returned in full (attack costs gas only).

## Root cause

`SessionRouter._extractProviderApproval` (MorpheusAIs/Morpheus-Lumerin-Node
@ ba14d2fd, `smart-contracts/contracts/diamond/facets/SessionRouter.sol`)
decodes the approval as `(bytes32, uint256, address, uint128)` and discards
the address field; `openSession` never compares it to `user_`. The error
`SessionApprovedForAnotherUser` is declared but never thrown.
