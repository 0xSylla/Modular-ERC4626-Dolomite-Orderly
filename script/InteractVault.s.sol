// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Script, console} from "forge-std/Script.sol";
import {DiracHoneyPotV1} from "../src/contracts/DiracHoneyPotV1.sol";
import {Data} from "../src/data/Data.sol";
import {IKXRouter} from "../src/interfaces/IKXRouter.sol";

contract InteractVault is Script {
    address public vaultAddr = vm.envOr("VAULT_ADDR", address(0));

    function setUp() public {
        if (vaultAddr == address(0)) {
            console.log(
                "WARNING: VAULT_ADDR environment variable not set. Use export VAULT_ADDR=... or set in .env"
            );
        }
    }

    function initializeCycle() external {
        _startBroadcast();
        DiracHoneyPotV1(payable(vaultAddr)).initializeCycle();
        vm.stopBroadcast();
        console.log("Trade cycle initialized.");
    }

    function startTradeCycle(uint256 duration) external {
        _startBroadcast();
        DiracHoneyPotV1(payable(vaultAddr)).startTradeCycle(duration);
        vm.stopBroadcast();
        console.log("Trade cycle started with duration:", duration);
    }

    function supplyCollateral(uint256 amount) external {
        _startBroadcast();
        DiracHoneyPotV1(payable(vaultAddr)).supplyCollateralToDolomite(amount);
        vm.stopBroadcast();
        console.log("Supplied collateral to Dolomite:", amount);
    }

    function borrowAsset(uint256 amount) external {
        _startBroadcast();
        DiracHoneyPotV1(payable(vaultAddr)).borrowAssetFromDolomite(amount);
        vm.stopBroadcast();
        console.log("Borrowed asset from Dolomite:", amount);
    }

    function swapKodiak(
        address tokenIn,
        bool wrapIn,
        uint256 amountIn,
        address tokenOut,
        bool unwrapOut,
        uint256 minAmountOut,
        IKXRouter.SwapData calldata swapDatas,
        IKXRouter.FeeData calldata feeDatas,
        address _spender
    ) external {
        _startBroadcast();
        DiracHoneyPotV1(payable(vaultAddr)).swapKodiak(
            tokenIn,
            wrapIn,
            amountIn,
            tokenOut,
            unwrapOut,
            minAmountOut,
            swapDatas,
            feeDatas
        );
        vm.stopBroadcast();
        console.log("Kodiak swap executed.");
    }

    /**
     * @notice Function to execute a Kodiak swap with parameters set inside the script.
     */
    function executeKodiakSwap() external {
        address tokenIn = 0x549943e04f40284185054145c6E4e9568C1D3241; // USDC example
        bool wrapIn = false;
        uint256 amountIn = 600000;
        address tokenOut = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b; // iBGT example
        bool unwrapOut = false;
        uint256 minAmountOut = 909466436664187191;
        address spender = 0x43Dac637c4383f91B4368041E7A8687da3806Cae;

        bytes
            memory swapHexData = hex"d2644d14000000000000000000000000549943e04f40284185054145c6e4e9568c1d3241000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000927c0000000000000000000000000ac03caba51e17c86c921e1f6cbfbdc91f8bb2e6b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c9f12e7d482593700000000000000000000000063e87bd96ace728a58a3586df40597df674b7f7a00000000000000000000000000000000000000000000000000000000000001800000000000000000000000000000000000000000000000000cb16c33f0dabd4e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000052bebb970697476313ae2b3383f40d4afd4ad9d30000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000044473fc4457000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000003f1037a01a0eb109d3935ea00b90b6ebe56e4606a1cdacf0b98549943e04f40284185054145c6e4e9568c1d3241ac03caba51e17c86c921e1f6cbfbdc91f8bb2e6be000d4c000d9f800e2e800e4a08c45154c6990293e59311097ae051946a4770edfad696fa284f3ddc399116f20903a149a55437965bb1545b24523653b86c2340104eb9c5cb12973aae6966f1b0000e0695bc94bc00c9f12e7d4825937f800e80927c0060300e3128acb08f80100000000000000000000000000000000000000000000000000000001000276a400000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000014549943e04f40284185054145c6e4e9568c1d32410000000000000000000000000100eb060300ef0300e30400f10080d667467e27cd3ff1845f08c2d9e638b57ddc75c300070a000000000000000000000000000000000000000000000000000000000000030194050020000000000000000000000000fffd8963efd1fc6a506488495d951d5263988d2500000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000014fcbd14dc51f0a4d49d5e53c2e0950e0bc26d0dce0000000000000000000000000100eb0603008a0500400401bb00803b9dba6dacf92eea27dff0a1f9c646e12d739df203019405006000000000000000000000000000000000000000000000000000000001000276a400000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000001469696969696969696969696969696969696969690000000000000000000000000100eb060300ef0500a0040264008005f8c238d14ecebd26b0c24e0e968f5cfbdc00a40301940500e0020070000206070706000000000000000000000000000000000000000000000000000000c00cbfb60171cea7b103031005012003033100020a0b0000000000000000000000000000000000000000000000000000000000030343050140030331eda49bce2f38d284f839be1f4f2e23e6c7cc7dbd02007002036d05016000050607080700000000000000000000000000000000000000000000000000000003038a05014003033105012002007002004805018002000000e700eb000000004001710180018007002001b501bb0000000040023b024a024a070020025e0264000000004002e402f302f30700200307030d0000060020030d03100000080020033a034300000700200364036d00000300000381038a000008002003ab03b7000003000003b703c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"; // Paste your hex data here

        IKXRouter.SwapData memory swapData = IKXRouter.SwapData({
            router: 0x52BeBb970697476313AE2B3383F40d4aFD4aD9D3,
            data: swapHexData
        });

        IKXRouter.FeeData memory feeData = IKXRouter.FeeData({
            feeQuote: 914631169672920398,
            surplusFeeBps: 0,
            refCode: 0,
            referrerFeeBps: 0
        });
        // -------------------------

        _startBroadcast();
        DiracHoneyPotV1(payable(vaultAddr)).swapKodiak(
            tokenIn,
            wrapIn,
            amountIn,
            tokenOut,
            unwrapOut,
            minAmountOut,
            swapData,
            feeData
        );
        vm.stopBroadcast();
        console.log("Kodiak swap executed from script values.");
    }

    function emergencyPause() external {
        _startBroadcast();
        DiracHoneyPotV1(payable(vaultAddr)).emergencyPause();
        vm.stopBroadcast();
        console.log("Vault paused.");
    }

    function emergencyUnpause() external {
        _startBroadcast();
        DiracHoneyPotV1(payable(vaultAddr)).emergencyUnpause();
        vm.stopBroadcast();
        console.log("Vault unpaused.");
    }

    function _startBroadcast() internal {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        require(deployerPrivateKey != 0, "PRIVATE_KEY not set");
        vm.startBroadcast(deployerPrivateKey);
    }
}
