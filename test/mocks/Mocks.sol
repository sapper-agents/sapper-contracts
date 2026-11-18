// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SapperBountyPot} from "../../src/SapperBountyPot.sol";

interface ITokenReceiver {
    function onTokenReceived(address from, uint256 amount) external;
}

/// Six-decimal permit token with an issuer-style blocklist (a blocked account can neither send nor
/// receive) and opt-in receiver hooks, so a recipient contract can refuse a transfer.
contract MockUSDG is ERC20, ERC20Permit {
    mapping(address => bool) public blocked;
    mapping(address => bool) public hooked;

    error Blocked(address account);

    constructor() ERC20("Global Dollar", "USDG") ERC20Permit("Global Dollar") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function setHooked(address account, bool value) external {
        hooked[account] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[from]) revert Blocked(from);
        if (blocked[to]) revert Blocked(to);
        super._update(from, to, value);
        if (hooked[to]) ITokenReceiver(to).onTokenReceived(from, value);
    }
}

/// A payee contract that refuses incoming tokens until told otherwise.
contract RejectingPayee is ITokenReceiver {
    bool public accepts;

    function setAccepts(bool value) external {
        accepts = value;
    }

    function onTokenReceived(address, uint256) external view {
        if (!accepts) revert("rejected");
    }

    function withdraw(SapperBountyPot pot, uint256 amount) external {
        pot.withdrawEarnings(amount);
    }
}

contract MockIdentity is ERC721 {
    uint256 public nextId = 1;

    constructor() ERC721("AgentIdentity", "AGENT") {}

    function register() external returns (uint256 agentId) {
        agentId = nextId++;
        _mint(msg.sender, agentId);
    }
}

contract OwnedTarget {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

contract AdminTarget {
    address public admin;

    constructor(address admin_) {
        admin = admin_;
    }
}

contract RoleTarget is AccessControl {
    constructor(address admin_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }
}

contract RevertingTarget {
    fallback() external {
        revert("nope");
    }
}

contract ShortReturnTarget {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(31, 1)
        }
    }
}

/// Returns `account` with a high bit set, which must not decode as `account`.
contract DirtyReturnTarget {
    address public immutable account;

    constructor(address account_) {
        account = account_;
    }

    fallback() external {
        uint256 word = uint256(uint160(account)) | (1 << 200);
        assembly {
            mstore(0, word)
            return(0, 32)
        }
    }
}

contract Wallet1271 {
    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
        return err == ECDSA.RecoverError.NoError && recovered == signer ? this.isValidSignature.selector : bytes4(0);
    }
}
