// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev Trivial target contract used by the TieredTimelock test suite.
contract TargetMock {
    error NotOwner();
    error AlwaysReverts();

    address public owner;
    uint256 public value;
    uint256 public secondValue;

    event ValueSet(uint256 newValue);
    event SecondValueSet(uint256 newValue);
    event Reentered();

    constructor(address owner_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setValue(uint256 newValue_) external onlyOwner {
        value = newValue_;
        emit ValueSet(newValue_);
    }

    function setSecondValue(uint256 newValue_) external onlyOwner {
        secondValue = newValue_;
        emit SecondValueSet(newValue_);
    }

    function revertingFunction() external pure {
        revert AlwaysReverts();
    }

    /// @dev Used by the reentrancy test. Calls back into the timelock during execution.
    function reenter(address timelock_, bytes calldata reentrantCall_) external onlyOwner {
        emit Reentered();
        (bool _ok, bytes memory _ret) = timelock_.call(reentrantCall_);
        // surface whatever the timelock returned
        if (!_ok) {
            assembly {
                revert(add(_ret, 32), mload(_ret))
            }
        }
    }

    function payableSink() external payable onlyOwner {
        value = msg.value;
    }

    /// @dev Mimics WETH.deposit() / vaETH.depositETH() — requires msg.value > 0.
    function depositETH() external payable onlyOwner {
        require(msg.value > 0, "no value");
        value = msg.value;
    }
}
