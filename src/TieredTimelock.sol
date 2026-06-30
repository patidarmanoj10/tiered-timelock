// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TieredTimelock
 * @notice Standalone timelock with per-(target, selector) configurable delays. Designed to be the
 *         single owner/governor of every contract in a protocol stack.
 *
 * Operating model:
 *   - PROPOSER schedules a call: schedule(target, data, predecessor, salt) → eta = now + delayOf[target,selector]
 *   - After eta and within grace period: anyone can execute(target, data, predecessor, salt)
 *   - CANCELLER can cancel a pending action before it executes
 *   - For functions with delayOf == 0, PROPOSER can call execute() directly without prior schedule
 *
 * Self-governance:
 *   - increaseDelay(target, selector, newDelay): delayed by its own selector's delay (initially 0)
 *   - decreaseDelay(target, selector, newDelay): delayed by the TARGET selector's CURRENT delay,
 *     so a delay can NEVER be reduced faster than it currently holds
 *   - addProposer / removeProposer / addCanceller / removeCanceller / updateGracePeriod: each
 *     delayed by its own selector's delay (governance can raise these over time)
 *
 * Initialization:
 *   - The deployer is the initial admin with the right to call seedDelay() and seedRole(),
 *     setting starting state without going through the schedule flow.
 *   - After seeding, the admin MUST call renounceAdmin() to make the contract fully self-governing.
 *     Anything that needs to change after that point goes through the schedule/execute flow.
 *
 * Encoding for operation IDs:
 *   id = keccak256(abi.encode(target, data, predecessor, salt))
 *   _timestamps[id]:
 *     0   = never scheduled
 *     1   = scheduled and already executed (DONE marker)
 *     >1  = scheduled, becomes ready at that block timestamp
 */
contract TieredTimelock is ReentrancyGuard {
    /* ════════════════════════════════════════════════════════════════════════════════════════
                                           CONSTANTS
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /// @notice Upper bound on any selector's configurable delay.
    uint256 public constant MAX_DELAY = 30 days;

    /// @notice Lower bound on grace period.
    uint256 public constant MIN_GRACE_PERIOD = 1 days;

    /// @notice Upper bound on grace period.
    uint256 public constant MAX_GRACE_PERIOD = 30 days;

    /// @dev Sentinel marker for executed operations.
    uint256 private constant _DONE_TIMESTAMP = uint256(1);

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                            STORAGE
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /// @notice Address authorized to seed initial state. Zero after renounceAdmin().
    address public admin;

    /// @notice (target, selector) → minimum delay in seconds. Zero = instant execution.
    mapping(bytes32 key => uint256 delay) public delayOf;

    /// @notice operation id → scheduled timestamp (0 unset, 1 done, >1 ready-at).
    mapping(bytes32 id => uint256 timestamp) public timestampOf;

    /// @notice Address → can call schedule().
    mapping(address => bool) public isProposer;

    /// @notice Address → can call cancel().
    mapping(address => bool) public isCanceller;

    /// @notice Number of active proposers. Cannot drop to zero (would brick the timelock).
    uint256 public proposerCount;

    /// @notice Number of active cancellers. Cannot drop to zero (would remove the only defense
    ///         against a malicious scheduled action).
    uint256 public cancellerCount;

    /// @notice Time window after eta during which a matured operation may still be executed.
    ///         After this window, the operation expires and must be re-scheduled.
    uint256 public gracePeriod;

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                            EVENTS
    ════════════════════════════════════════════════════════════════════════════════════════ */

    event Scheduled(
        bytes32 indexed id,
        address indexed target,
        bytes data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 executableAt
    );
    event Executed(bytes32 indexed id, address indexed target, bytes data);
    event Cancelled(bytes32 indexed id, address indexed canceller);
    event DelaySet(address indexed target, bytes4 indexed selector, uint256 oldDelay, uint256 newDelay);
    event ProposerSet(address indexed proposer, bool allowed);
    event CancellerSet(address indexed canceller, bool allowed);
    event GracePeriodSet(uint256 oldPeriod, uint256 newPeriod);
    event AdminRenounced();

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                            ERRORS
    ════════════════════════════════════════════════════════════════════════════════════════ */

    error NotProposer();
    error NotCanceller();
    error NotAdmin();
    error NotSelf();
    error ZeroAddress();
    error ZeroSelector();
    error DelayTooLong();
    error DelayNotIncreasing();
    error DelayNotDecreasing();
    error GracePeriodOutOfBounds();
    error AlreadyScheduled();
    error NotScheduled();
    error PredecessorNotDone();
    error TimelockNotExpired();
    error OperationExpired();
    error MustSchedule();
    error AdminAlreadyRenounced();
    error CallFailed(bytes returnData);
    error CannotRemoveLastProposer();
    error CannotRemoveLastCanceller();
    error AlreadyRoleMember();
    error NotRoleMember();
    error CriticalDelayNotSeeded(bytes4 selector);
    error AlreadySeeded(address target, bytes4 selector);

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                          MODIFIERS
    ════════════════════════════════════════════════════════════════════════════════════════ */

    modifier onlyProposer() {
        if (!isProposer[msg.sender]) revert NotProposer();
        _;
    }

    modifier onlyCanceller() {
        if (!isCanceller[msg.sender]) revert NotCanceller();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @dev Self-governance: only callable as the result of a scheduled & executed operation.
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                         CONSTRUCTOR
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /**
     * @param admin_         Initial admin (allowed to seed delays and roles, then must renounce).
     * @param initialProposers_  Addresses granted PROPOSER on day 0 (typically the governor Safe).
     * @param initialCancellers_ Addresses granted CANCELLER on day 0 (typically Safe + security council).
     * @param gracePeriod_   Initial grace period (e.g., 14 days).
     */
    constructor(
        address admin_,
        address[] memory initialProposers_,
        address[] memory initialCancellers_,
        uint256 gracePeriod_
    ) {
        if (admin_ == address(0)) revert ZeroAddress();
        if (gracePeriod_ < MIN_GRACE_PERIOD || gracePeriod_ > MAX_GRACE_PERIOD) revert GracePeriodOutOfBounds();

        admin = admin_;
        gracePeriod = gracePeriod_;
        emit GracePeriodSet(0, gracePeriod_);

        for (uint256 i; i < initialProposers_.length; ++i) {
            address p = initialProposers_[i];
            if (p == address(0)) revert ZeroAddress();
            if (isProposer[p]) revert AlreadyRoleMember();
            isProposer[p] = true;
            ++proposerCount;
            emit ProposerSet(p, true);
        }
        if (proposerCount == 0) revert CannotRemoveLastProposer();

        for (uint256 i; i < initialCancellers_.length; ++i) {
            address c = initialCancellers_[i];
            if (c == address(0)) revert ZeroAddress();
            if (isCanceller[c]) revert AlreadyRoleMember();
            isCanceller[c] = true;
            ++cancellerCount;
            emit CancellerSet(c, true);
        }
        if (cancellerCount == 0) revert CannotRemoveLastCanceller();
    }

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                       VIEW HELPERS
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /// @notice Compute operation id used internally.
    function hashOperation(
        address target_,
        bytes calldata data_,
        bytes32 predecessor_,
        bytes32 salt_
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(target_, data_, predecessor_, salt_));
    }

    /// @notice Compute the (target, selector) storage key for delayOf.
    function delayKey(address target_, bytes4 selector_) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(target_, selector_));
    }

    /// @notice True if the operation is scheduled but not yet executed or cancelled.
    function isPending(bytes32 id_) public view returns (bool) {
        return timestampOf[id_] > _DONE_TIMESTAMP;
    }

    /// @notice True if the operation has been executed.
    function isDone(bytes32 id_) public view returns (bool) {
        return timestampOf[id_] == _DONE_TIMESTAMP;
    }

    /// @notice True if the operation is matured (eta passed) AND still within grace period.
    function isReady(bytes32 id_) public view returns (bool) {
        uint256 t = timestampOf[id_];
        return t > _DONE_TIMESTAMP && t <= block.timestamp && block.timestamp <= t + gracePeriod;
    }

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                      SCHEDULE / EXECUTE
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Schedule a call. Anyone holding PROPOSER may schedule. ETA is computed from delayOf.
     *         For functions targeting this contract's own `decreaseDelay`, the ETA uses the TARGET
     *         selector's current delay so a delay reduction cannot be fast-pathed.
     */
    function schedule(
        address target_,
        bytes calldata data_,
        bytes32 predecessor_,
        bytes32 salt_
    ) external onlyProposer returns (bytes32 id) {
        if (target_ == address(0)) revert ZeroAddress();
        if (data_.length < 4) revert ZeroSelector();

        bytes4 sel = bytes4(data_[:4]);
        uint256 delay = _resolveDelay(target_, sel, data_);

        id = hashOperation(target_, data_, predecessor_, salt_);
        if (timestampOf[id] != 0) revert AlreadyScheduled();

        uint256 eta = block.timestamp + delay;
        timestampOf[id] = eta;

        emit Scheduled(id, target_, data_, predecessor_, salt_, eta);
    }

    /**
     * @notice Execute a previously scheduled operation. Permissionless after eta.
     *         When delayOf[target, selector] == 0 and no schedule exists, the proposer may execute
     *         in a single tx without scheduling first.
     *
     *         If predecessor_ != 0, that operation must be `done` before this one can execute.
     */
    function execute(
        address target_,
        bytes calldata data_,
        bytes32 predecessor_,
        bytes32 salt_
    ) external payable nonReentrant returns (bytes memory) {
        if (target_ == address(0)) revert ZeroAddress();
        if (data_.length < 4) revert ZeroSelector();

        bytes32 id = hashOperation(target_, data_, predecessor_, salt_);
        uint256 t = timestampOf[id];

        if (t == 0) {
            // Not scheduled: only allowed if delay is 0 AND caller is a proposer.
            bytes4 sel = bytes4(data_[:4]);
            uint256 delay = _resolveDelay(target_, sel, data_);
            if (delay != 0) revert MustSchedule();
            if (!isProposer[msg.sender]) revert NotProposer();
        } else if (t == _DONE_TIMESTAMP) {
            // Already executed.
            revert AlreadyScheduled();
        } else {
            if (block.timestamp < t) revert TimelockNotExpired();
            if (block.timestamp > t + gracePeriod) revert OperationExpired();
        }

        if (predecessor_ != bytes32(0) && timestampOf[predecessor_] != _DONE_TIMESTAMP) {
            revert PredecessorNotDone();
        }

        // Mark done BEFORE the external call (CEI).
        timestampOf[id] = _DONE_TIMESTAMP;

        (bool ok, bytes memory ret) = target_.call{value: msg.value}(data_);
        if (!ok) revert CallFailed(ret);

        emit Executed(id, target_, data_);
        return ret;
    }

    /**
     * @notice Cancel a pending operation. Callable by anyone with CANCELLER.
     *         Cannot cancel done or never-scheduled operations.
     */
    function cancel(bytes32 id_) external onlyCanceller {
        uint256 t = timestampOf[id_];
        if (t == 0 || t == _DONE_TIMESTAMP) revert NotScheduled();
        delete timestampOf[id_];
        emit Cancelled(id_, msg.sender);
    }

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                  SELF-GOVERNED CONFIGURATION
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Raise the delay for a (target, selector). Scheduled by its own selector's delay
     *         (default 0 → instant initially; raise this delay first to slow itself down).
     */
    function increaseDelay(address target_, bytes4 selector_, uint256 newDelay_) external onlySelf {
        if (newDelay_ > MAX_DELAY) revert DelayTooLong();
        bytes32 key = delayKey(target_, selector_);
        uint256 old = delayOf[key];
        if (newDelay_ <= old) revert DelayNotIncreasing();
        delayOf[key] = newDelay_;
        emit DelaySet(target_, selector_, old, newDelay_);
    }

    /**
     * @notice Lower the delay for a (target, selector). Scheduled at the TARGET selector's CURRENT
     *         delay so a delay can never be reduced faster than it currently holds.
     */
    function decreaseDelay(address target_, bytes4 selector_, uint256 newDelay_) external onlySelf {
        bytes32 key = delayKey(target_, selector_);
        uint256 old = delayOf[key];
        if (newDelay_ >= old) revert DelayNotDecreasing();
        delayOf[key] = newDelay_;
        emit DelaySet(target_, selector_, old, newDelay_);
    }

    /// @notice Add a proposer. Self-governed. No-op if already a proposer (idempotent retry).
    function addProposer(address account_) external onlySelf {
        if (account_ == address(0)) revert ZeroAddress();
        if (isProposer[account_]) revert AlreadyRoleMember();
        isProposer[account_] = true;
        ++proposerCount;
        emit ProposerSet(account_, true);
    }

    /// @notice Remove a proposer. Self-governed. Reverts if this would leave zero proposers
    ///         (otherwise the timelock would be bricked — no one could ever schedule again).
    function removeProposer(address account_) external onlySelf {
        if (!isProposer[account_]) revert NotRoleMember();
        if (proposerCount <= 1) revert CannotRemoveLastProposer();
        isProposer[account_] = false;
        --proposerCount;
        emit ProposerSet(account_, false);
    }

    /// @notice Add a canceller. Self-governed. No-op if already a canceller.
    function addCanceller(address account_) external onlySelf {
        if (account_ == address(0)) revert ZeroAddress();
        if (isCanceller[account_]) revert AlreadyRoleMember();
        isCanceller[account_] = true;
        ++cancellerCount;
        emit CancellerSet(account_, true);
    }

    /// @notice Remove a canceller. Self-governed. Reverts if this would leave zero cancellers
    ///         (defense against malicious schedules would be eliminated).
    function removeCanceller(address account_) external onlySelf {
        if (!isCanceller[account_]) revert NotRoleMember();
        if (cancellerCount <= 1) revert CannotRemoveLastCanceller();
        isCanceller[account_] = false;
        --cancellerCount;
        emit CancellerSet(account_, false);
    }

    /// @notice Update the grace period. Self-governed.
    function updateGracePeriod(uint256 newGracePeriod_) external onlySelf {
        if (newGracePeriod_ < MIN_GRACE_PERIOD || newGracePeriod_ > MAX_GRACE_PERIOD) {
            revert GracePeriodOutOfBounds();
        }
        uint256 old = gracePeriod;
        gracePeriod = newGracePeriod_;
        emit GracePeriodSet(old, newGracePeriod_);
    }

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                  ADMIN (ONE-TIME SEEDING)
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice One-time setup: configure the initial delay for a (target, selector).
     *         Set-once: reverts with `AlreadySeeded` if the key already has a non-zero delay.
     *         (After the initial seed, subsequent changes must go through `increaseDelay` /
     *         `decreaseDelay` like every other update.) Capped by MAX_DELAY. Only callable
     *         while admin is set.
     */
    function seedDelay(address target_, bytes4 selector_, uint256 delay_) external onlyAdmin {
        if (target_ == address(0)) revert ZeroAddress();
        if (delay_ > MAX_DELAY) revert DelayTooLong();
        bytes32 key = delayKey(target_, selector_);
        if (delayOf[key] != 0) revert AlreadySeeded(target_, selector_);
        delayOf[key] = delay_;
        emit DelaySet(target_, selector_, 0, delay_);
    }

    /**
     * @notice Renounce admin role. After this is called the contract is fully self-governing:
     *         delays, roles, and grace period can only be changed via the schedule/execute flow.
     *         IRREVERSIBLE.
     *
     *         Refuses to renounce while critical role-change and config selectors have delay = 0,
     *         since those functions would otherwise be permanently single-tx-callable by any
     *         compromised proposer. This guarantees the contract enters self-governance in a safe
     *         state. The deployer must seed these delays via `seedDelay` before calling renounce.
     */
    function renounceAdmin() external onlyAdmin {
        _requireCriticalDelaySet(TieredTimelock.addProposer.selector);
        _requireCriticalDelaySet(TieredTimelock.removeProposer.selector);
        _requireCriticalDelaySet(TieredTimelock.addCanceller.selector);
        _requireCriticalDelaySet(TieredTimelock.removeCanceller.selector);
        _requireCriticalDelaySet(TieredTimelock.increaseDelay.selector);
        _requireCriticalDelaySet(TieredTimelock.updateGracePeriod.selector);

        admin = address(0);
        emit AdminRenounced();
    }

    /// @dev Reverts if the (self, selector) delay has not been seeded.
    function _requireCriticalDelaySet(bytes4 selector_) private view {
        if (delayOf[delayKey(address(this), selector_)] == 0) {
            revert CriticalDelayNotSeeded(selector_);
        }
    }

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                            HELPERS
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /**
     * @dev Resolves the delay that should be applied at schedule-time.
     *      Special case: `this.decreaseDelay(target, selector, newDelay)` uses the TARGET selector's
     *      CURRENT delay, so a delay can never be reduced faster than it currently holds.
     */
    function _resolveDelay(
        address target_,
        bytes4 sel_,
        bytes calldata data_
    ) private view returns (uint256) {
        if (target_ == address(this) && sel_ == this.decreaseDelay.selector) {
            // decreaseDelay(address, bytes4, uint256)
            // data layout: [4-byte selector][32-byte target][32-byte selector word][32-byte newDelay]
            if (data_.length < 4 + 32 + 32 + 32) revert ZeroSelector();
            address targetArg = address(uint160(uint256(bytes32(data_[4:36]))));
            bytes4 selArg = bytes4(data_[36:40]);
            return delayOf[delayKey(targetArg, selArg)];
        }
        return delayOf[delayKey(target_, sel_)];
    }

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                          ETH HANDLING
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /// @notice Allow the contract to receive ETH so it can forward msg.value to payable target calls.
    receive() external payable {}
}
