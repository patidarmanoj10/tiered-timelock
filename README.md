# TieredTimelock

A standalone, non-upgradeable timelock contract with **per-function configurable delays**, designed to be the single owner/governor of every contract in a protocol stack.

## Why this contract exists

DeFi governance contracts typically fall into two extremes:

1. **No timelock** — the multisig can execute any change instantly. Fast in normal operation, but a compromised multisig can rug the protocol in one transaction.
2. **OpenZeppelin `TimelockController`** — every governance action waits the same `minDelay`. Safer, but operationally clumsy: tuning a gas-limit parameter and replacing the price oracle both have to wait the same amount of time.

Most real protocols want something in between: **slow for rug-risk changes, fast for operational tuning, instant for emergency response.** This contract gives you that without forking the OZ codebase or building a custom governance system from scratch.

### What this gives you

| Need | TieredTimelock |
|---|---|
| Different delays for different functions | ✅ `delayOf[(target, selector)]` is per-function |
| Zero delay for some functions (operational/keeper actions) | ✅ Functions with `delayOf == 0` execute in a single tx |
| Cancellation by a separate role | ✅ `CANCELLER_ROLE` distinct from `PROPOSER_ROLE` |
| Self-governance after deploy | ✅ Admin renounces; delays/roles change only via timelock-of-itself |
| Cannot fast-path a delay reduction | ✅ `decreaseDelay` takes the target's *current* delay |
| Cannot orphan the contract | ✅ `proposerCount >= 1` and `cancellerCount >= 1` invariants enforced |
| Cannot ship in an unsafe state | ✅ `renounceAdmin` reverts if critical role-change delays are unset |
| Predecessor dependencies (op B requires op A done) | ✅ `predecessor` parameter on `schedule`/`execute` |
| Permissionless execution after eta | ✅ Anyone can execute a matured scheduled action |
| Grace period (matured ops expire if not executed in time) | ✅ Configurable, bounded `[1 day, 30 days]` |

## How it works

### Lifecycle: deployment → self-governance

```
Deployment phase                  Self-governing phase
─────────────────────────  ─────────────────────────────────
admin = deployer EOA/Safe         admin = address(0)

seedDelay() ✓ (direct write)      seedDelay() ✗ (admin = 0)
increaseDelay() ✓ (via execute,   increaseDelay() ✓ (via schedule →
   single-tx if its delay is 0)      wait → execute, delay > 0)

renounceAdmin() ◄──── crossing point (one-way, irreversible)
```

### Standard flow for a delayed change

```
                           +-- delay --+
[Safe]──schedule────────►──┤            ├──►──execute────►──[target.call(...)]
                           +------------+        ↑
                                                 │
                                            Anyone can execute
                                            after the eta
```

### Emergency cancellation flow

```
[Safe]──schedule────►──[pending]────►──(would execute later)
                            │
                            │
                         cancel()
                            ▲
                            │
                  [Security Council canceller]
```

### Per-function delay model

The delay applied to a scheduled operation is looked up from a `(target, selector)` mapping:

```solidity
mapping(bytes32 key => uint256 delay) public delayOf;
// key = keccak256(abi.encodePacked(target, selector))
```

A protocol might configure:

| Target | Function | Delay |
|---|---|---|
| Pool | `updateCollateralFactor` | 7 days |
| Pool | `updateInterestRate` | 2 days |
| PoolRegistry | `updateMasterOracle` | 7 days |
| FeeProvider | `updateWithdrawFee` | 2 days |
| Pool | `pause` | 0 (via guardian path — not even routed through timelock) |
| Keeper | `harvest` | 0 |

Functions with delay = 0 still go through the timelock contract (the proposer must call `execute`), but skip the schedule/wait step.

### Roles

| Role | Granted to | Can do |
|---|---|---|
| **Admin** | One EOA/Safe at deployment | `seedDelay` (set-once per key), `renounceAdmin` |
| **Proposer** | Governance Safe(s) | `schedule`, `execute` for delay-0 paths |
| **Canceller** | Safe + separate security council (recommended) | `cancel` a pending operation before its eta |
| **Anyone** | n/a | `execute` a matured scheduled operation |

After `renounceAdmin`, role grants and revocations are self-governed — they go through the same schedule/execute flow.

## Key security properties

### 1. Cannot fast-path delay reductions

`decreaseDelay(target, sel, newDelay)` uses the **target selector's CURRENT delay** at schedule time:

```solidity
// Pool.updateCollateralFactor has delay = 7 days
// Proposer schedules decreaseDelay(Pool, updateCollateralFactor.selector, 1 hour)
// → that schedule must wait 7 days, not 0
```

A compromised proposer cannot reduce a 7-day delay to 1 hour faster than 7 days. The protection scales with the delay you're trying to bypass.

### 2. Cannot orphan the contract

- `removeProposer` reverts if it would set `proposerCount` to 0 — the timelock would otherwise be bricked (no one could ever schedule).
- `removeCanceller` reverts if it would set `cancellerCount` to 0 — the canceller role exists specifically as a defense against malicious schedules; eliminating it would defeat the purpose.

### 3. Cannot ship in an unsafe configuration

`renounceAdmin` refuses to renounce if any of these critical (self, selector) delays is still 0:

- `addProposer`, `removeProposer`
- `addCanceller`, `removeCanceller`
- `increaseDelay`
- `updateGracePeriod`

The deployer is forced to seed real delays on the role-management surface before the contract enters self-governing mode. After renounce, these delays are guaranteed `> 0` and can only be increased (since `decreaseDelay` requires the current delay).

### 4. Permissionless execution avoids liveness gaps

Once a scheduled operation's eta passes, **anyone** can execute it. The proposer doesn't need to come back and pay gas; bots or any user can complete the action. Reduces protocol downtime if the proposer Safe is unavailable.

### 5. CEI ordering inside `execute`

```solidity
timestampOf[id] = _DONE_TIMESTAMP;       // mark done first
(bool ok, ...) = target.call{...}(data); // external call second
```

Combined with `nonReentrant`, this means a reentering target cannot re-execute the same operation.

### 6. Grace period auto-expires stale operations

A matured operation that nobody executes within `gracePeriod` (default 14 days) expires and must be re-scheduled. Prevents a stale-but-still-valid operation from suddenly landing months later in an unexpected world state.

## Usage

### Deployment

```solidity
address[] memory proposers = new address[](1);
proposers[0] = SAFE_ADDRESS;

address[] memory cancellers = new address[](2);
cancellers[0] = SAFE_ADDRESS;
cancellers[1] = SECURITY_COUNCIL_ADDRESS;   // strongly recommended: separate canceller

TieredTimelock timelock = new TieredTimelock(
    deployerAdmin,   // an EOA or simple multisig used during init only
    proposers,
    cancellers,
    14 days          // grace period
);
```

### Seeding initial delays (admin path, one-time)

```solidity
// Critical role-change delays — required by renounceAdmin
timelock.seedDelay(address(timelock), TieredTimelock.addProposer.selector,       3 days);
timelock.seedDelay(address(timelock), TieredTimelock.removeProposer.selector,    3 days);
timelock.seedDelay(address(timelock), TieredTimelock.addCanceller.selector,      3 days);
timelock.seedDelay(address(timelock), TieredTimelock.removeCanceller.selector,   3 days);
timelock.seedDelay(address(timelock), TieredTimelock.increaseDelay.selector,     1 days);
timelock.seedDelay(address(timelock), TieredTimelock.updateGracePeriod.selector, 1 days);

// Per-target delays — from your protocol's risk matrix
timelock.seedDelay(POOL,         IPool.updateCollateralFactor.selector, 7 days);
timelock.seedDelay(POOL,         IPool.updateInterestRate.selector,     2 days);
timelock.seedDelay(POOL_REGISTRY, IPoolRegistry.updateMasterOracle.selector, 7 days);
// ... etc

// Hand off
timelock.renounceAdmin();  // reverts if any critical delay above is still 0
```

### Day-to-day governance (after renounce)

A delayed change:

```solidity
// Step 1: propose
bytes memory data = abi.encodeCall(IPool.updateCollateralFactor, (token, 8e17));
bytes32 id = timelock.schedule(POOL, data, bytes32(0), bytes32(0));

// Step 2: wait (eta = now + 7 days)

// Step 3: execute (anyone can call this after eta)
timelock.execute(POOL, data, bytes32(0), bytes32(0));
```

A delay-0 change (single-tx, proposer only):

```solidity
bytes memory data = abi.encodeCall(IPool.someOperationalFunc, (...));
timelock.execute(POOL, data, bytes32(0), bytes32(0));  // executes immediately
```

Cancelling a pending change:

```solidity
timelock.cancel(id);  // canceller-only, before the operation executes
```

## Design choices

### Why standalone, not a mixin?

`TimelockedUpgradeable` (the Morpho V2 pattern) is a great mixin design — but it requires every governed contract to inherit it and add `scheduleXxx`/`_tryConsume`-guarded entry points. That's a substantial code change across a large protocol.

This contract is **standalone**: it becomes the single owner of every governed contract, and routes calls through itself. No changes to existing contracts beyond transferring ownership/governance.

### Why per-(target, selector) not just per-selector?

Multiple contracts in a protocol can have the same selector (e.g., `updateMaxTotalSupply` on both DebtToken and DepositToken). Keying by `(target, selector)` lets the same selector have different delays on different contracts.

### Why non-upgradeable?

A security-critical contract that holds the keys to a protocol should be immutable. If a bug is found, deploy a new TieredTimelock and migrate ownership — but make that migration explicit and slow.

### Why no global `EXECUTOR_ROLE`?

Matured scheduled operations are executable by anyone — this is the standard pattern in OZ TimelockController and Morpho. Restricting execution to specific addresses creates a liveness risk if those addresses are unavailable; the operation is already authorized at schedule time.

For `delay = 0` operations (no prior schedule), the proposer must call `execute` (auth happens at execute time since there was no schedule). This is correct and matches yield-vault's `_tryConsume` shape.

## Comparison

| Feature | OZ TimelockController | yield-vault / Morpho V2 mixin | **TieredTimelock** |
|---|---|---|---|
| Per-function delay | ❌ (single `minDelay`) | ✅ | ✅ |
| Standalone (no contract modifications needed) | ✅ | ❌ (mixin) | ✅ |
| Cannot fast-path delay reductions | ❌ | ✅ | ✅ |
| `delay = 0` instant path | ❌ (only via `minDelay = 0` global) | ✅ (`_tryConsume`) | ✅ |
| Pre-renounce admin seeding | ❌ | ✅ (`_seedTimelock`) | ✅ (`seedDelay`) |
| Enforces critical delays seeded before handoff | ❌ | ❌ | ✅ (`renounceAdmin` check) |
| Cannot orphan (count ≥ 1 invariant) | partial | ❌ | ✅ |
| Grace period | ✅ | ❌ | ✅ |
| Predecessor IDs | ✅ | ❌ | ✅ |
| Per-(target, selector) keying | n/a (one minDelay) | per-selector only | ✅ |

## Status

This contract has **NOT yet been audited**. Do not deploy to mainnet without a security review.

The test suite covers:
- Constructor invariants and role setup
- `seedDelay` set-once and revert-on-double-set
- `renounceAdmin` critical-delay check
- Schedule → wait → permissionless execute happy path
- `delay = 0` shortcut path
- Predecessor dependency enforcement
- Grace-period expiry
- Cancellation flow
- `increaseDelay` monotonicity and `MAX_DELAY` cap
- `decreaseDelay` invariant (uses target's current delay)
- Role-management with `proposerCount`/`cancellerCount` floors
- `onlySelf` guards on all governance functions
- Reentrancy guard

37 tests, all passing.

## Build & test

```bash
git clone --recurse-submodules git@github.com:patidarmanoj10/tiered-timelock.git
cd tiered-timelock
forge test
```

Compiler: `solc 0.8.24`. Submodules: `forge-std`, `openzeppelin-contracts` (v5.0.2 — used only for `ReentrancyGuard`).

## License

MIT.
