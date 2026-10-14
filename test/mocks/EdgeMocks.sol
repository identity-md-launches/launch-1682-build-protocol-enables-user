// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Reverts on `approve` when the spender is blocked. Models honeypots that refuse to let
/// holders approve the router, which hits SwarmExit's refund path (`forceApprove(router, 0)`).
contract ApproveBlockingToken is ERC20 {
    mapping(address => bool) public blockedSpender;

    constructor() ERC20("ApproveBlock", "ABL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlockedSpender(address who, bool blocked) external {
        blockedSpender[who] = blocked;
    }

    function _approve(address owner_, address spender, uint256 value, bool emitEvent) internal override {
        require(!blockedSpender[spender], "ABL: approve blocked");
        super._approve(owner_, spender, value, emitEvent);
    }
}

/// @notice Blocks every transfer *to* a configured address (a user that the token has blacklisted),
/// so a refund back to that user reverts.
contract RefundBlockingToken is ERC20 {
    mapping(address => bool) public blockedRecipient;

    constructor() ERC20("RefundBlock", "RBL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address who, bool blocked) external {
        blockedRecipient[who] = blocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blockedRecipient[to], "RBL: recipient blocked");
        super._update(from, to, value);
    }
}

/// @notice Lies about balances: `balanceOf` reports more than the holder can transfer.
contract OverReportingToken is ERC20 {
    uint256 public extra;

    constructor() ERC20("Liar", "LIE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setExtra(uint256 e) external {
        extra = e;
    }

    function balanceOf(address who) public view override returns (uint256) {
        return super.balanceOf(who) + extra;
    }
}

/// @notice ERC20 that burns everything on every transfer (100% fee): the venue receives nothing.
contract AllBurnToken is ERC20 {
    constructor() ERC20("Burn", "BRN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            super._update(from, address(0), value);
            return;
        }
        super._update(from, to, value);
    }
}

/// @notice Burns all remaining gas when a transfer targets `sink` (a venue), so the inner self-call
/// of SwarmExit runs out of gas instead of reverting cleanly.
contract GasBurnToken is ERC20 {
    address public sink;

    constructor() ERC20("GasBurn", "GAS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setSink(address s) external {
        sink = s;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to == sink) {
            uint256 x;
            while (true) {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
        super._update(from, to, value);
    }
}

/// @notice Returns `false` (without reverting or moving anything) from `transfer` / `transferFrom`
/// when the recipient is blocked. Exercises SwarmExit's "transfer returned false" rule, which must
/// be treated exactly like a revert: a failed pull or a held refund, never a settled sale.
contract FalseReturnToken is ERC20 {
    mapping(address => bool) public blockedRecipient;

    constructor() ERC20("FalseReturn", "FLS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address who, bool blocked) external {
        blockedRecipient[who] = blocked;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (blockedRecipient[to]) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (blockedRecipient[to]) return false;
        return super.transferFrom(from, to, value);
    }
}

/// @notice Chainlink feed whose `latestRoundData` reverts (feed paused / deprecated).
contract RevertingFeed {
    uint8 public constant decimals = 8;

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("feed down");
    }
}
