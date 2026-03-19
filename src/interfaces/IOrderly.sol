// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;


library VaultTypes {

    struct VaultDelegate {
        bytes32 brokerHash;
        address delegateSigner;
    }

    struct VaultDepositFE {
        bytes32 accountId;
        bytes32 brokerHash;
        bytes32 tokenHash;
        uint128 tokenAmount;
    }

    struct VaultDeposit {
        bytes32 accountId;
        address userAddress;
        bytes32 brokerHash;
        bytes32 tokenHash;
        uint128 tokenAmount;
        uint64 depositNonce; // deposit nonce
    }

    struct VaultWithdraw {
        bytes32 accountId;
        bytes32 brokerHash;
        bytes32 tokenHash;
        uint128 tokenAmount;
        uint128 fee;
        address sender;
        address receiver;
        uint64 withdrawNonce; // withdraw nonce
    }
    enum VaultEnum {
        ProtocolVault,
        UserVault,
        Ceffu
    }

    struct VaultWithdraw2Contract {
        VaultEnum vaultType;
        bytes32 accountId;
        bytes32 brokerHash;
        bytes32 tokenHash;
        uint128 tokenAmount;
        uint128 fee;
        address sender;
        address receiver;
        uint64 withdrawNonce;
        uint256 clientId;
    }

}

interface IVault {
    function delegateSigner(VaultTypes.VaultDelegate calldata data) external;
    function deposit(VaultTypes.VaultDepositFE calldata data) external payable;
    function withdraw2Contract(VaultTypes.VaultWithdraw2Contract calldata data) external;
    function getDepositFee(address sender, VaultTypes.VaultDepositFE calldata data) external view returns (uint256);
}
