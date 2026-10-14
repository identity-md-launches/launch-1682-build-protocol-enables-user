// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain mintable ERC20 (also used, etched, as the IMD stand-in in tests).
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Charges a fee on every transfer, burned.
contract FeeOnTransferToken is ERC20 {
    uint256 public immutable feeBps;

    constructor(uint256 feeBps_) ERC20("Fee Token", "FEE") {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (value * feeBps) / 10_000;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @notice Honeypot: anyone can buy and hold, but transfers into the configured venues revert.
contract HoneypotToken is ERC20 {
    mapping(address => bool) public blockedRecipient;

    constructor() ERC20("Honeypot", "HONEY") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address who, bool blocked) external {
        blockedRecipient[who] = blocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blockedRecipient[to], "HONEY: sell blocked");
        super._update(from, to, value);
    }
}

interface ISellAll {
    function sellAll(address[] calldata tokens, uint256[] calldata minImdOuts, uint256 deadline)
        external
        returns (bytes memory);
}

/// @notice Tries to re-enter `sellAll` from inside transferFrom.
contract ReentrantToken is ERC20 {
    address public target;
    bool public attempted;
    bool public reentered;

    constructor() ERC20("Reentrant", "RE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTarget(address t) external {
        target = t;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to == target && !attempted) {
            attempted = true;
            address[] memory tokens = new address[](1);
            tokens[0] = address(this);
            uint256[] memory mins = new uint256[](1);
            (bool ok,) = target.call(
                abi.encodeWithSignature("sellAll(address[],uint256[],uint256)", tokens, mins, block.timestamp + 1)
            );
            reentered = ok;
        }
    }
}
