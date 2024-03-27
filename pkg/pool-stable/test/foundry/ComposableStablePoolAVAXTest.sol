pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console2 } from "forge-std/console2.sol";

import { ComposableStablePool } from "../../contracts/ComposableStablePool.sol";
import { ComposableStablePoolFactory } from "../../contracts/ComposableStablePoolFactory.sol";

import "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";
import "@balancer-labs/v2-interfaces/contracts/pool-utils/IRateProvider.sol";
import "@balancer-labs/v2-interfaces/contracts/standalone-utils/IProtocolFeePercentagesProvider.sol";
import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v2-interfaces/contracts/pool-stable/StablePoolUserData.sol";

import "@balancer-labs/v2-solidity-utils/contracts/helpers/ERC20Helpers.sol";

contract ComposableStablePoolAVAXTest is Test {
    address constant COMPOSABLE_STABLE_POOL_FACTORY = 0xE42FFA682A26EF8F25891db4882932711D42e467;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E; // NATIVE USDC
    address constant USDC_HOLDER = 0x7E4aA755550152a522d9578621EA22eDAb204308;
    address constant AUX = 0x68327a91E79f87F501bC8522fc333FB7A72393cb;
    address constant AUX_HOLDER = 0x247A0a7EeebEe038ED88233FFb48d6695fb15211;
    address constant VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    function testTransferFeeTokenPool() public {
        string memory rpcURL = vm.envString("AVALANCHE_RPC_URL");
        vm.createSelectFork(rpcURL, 30058683);

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(AUX);
        tokens[1] = IERC20(USDC);

        ComposableStablePool csp = new ComposableStablePool(
            ComposableStablePool.NewPoolParams({
                vault: IVault(VAULT),
                // vault: vault,
                protocolFeeProvider: IProtocolFeePercentagesProvider(0x239e55F427D44C3cc793f49bFB507ebe76638a2b),
                name: "USDC-AUX-BPT",
                symbol: "USDC-AUX-BPT",
                tokens: tokens,
                rateProviders: new IRateProvider[](2), // rateProviders
                tokenRateCacheDurations: new uint256[](2), // tokenRateCacheDurations
                exemptFromYieldProtocolFeeFlags: new bool[](2), // exemptFromYieldProtocolFeeFlags
                amplificationParameter: 5000, // ampFactor
                swapFeePercentage: 1e12, // swapFeePercentage
                pauseWindowDuration: 0, // pauseWindowDuration
                bufferPeriodDuration: 0, // bufferPeriodDuration
                owner: address(this), // owner
                version: "5"
            })
        );

        _joinPool(IVault(VAULT), csp);
        // _exitPool(IVault(VAULT), csp);

        console2.log("lp bal:", IERC20(address(csp)).balanceOf(address(this)));

        // ComposableStablePoolFactory factory = ComposableStablePoolFactory(COMPOSABLE_STABLE_POOL_FACTORY);
        // // using constructor params from USDC-USDT-BPT pool: https://snowtrace.io/tx/0x3b9061cefc69ca19b0f52a7c0b550225c7945a9ed725db636a7ed18a03cbc957?chainId=43114
        // console2.log("creating pool");
        // factory.create(
        //     "USDC-AUX-BPT",
        //     "USDC-AUX-BPT",
        //     tokens, // tokens
        //     5000, // ampFactor
        //     new IRateProvider[](2), // rateProviders
        //     new uint256[](0), // tokenRateCacheDurations
        //     new bool[](0), // exemptFromYieldProtocolFeeFlags
        //     0, // swapFeePercentage
        //     address(this), // owner
        //     bytes32(uint256(uint160(address(this))) << 96) // salt
        // );
    }

    function _joinPool(IVault _vault, ComposableStablePool csp) internal {
        _setupTokenAllowance(_vault);

        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(address(csp)); // bpt token
        tokens[1] = IERC20(AUX);
        tokens[2] = IERC20(USDC);
        uint256[] memory maxAmountsIn = new uint256[](3);
        maxAmountsIn[0] = 1e36;
        maxAmountsIn[1] = 1e36;
        maxAmountsIn[2] = 1e36;

        uint256[] memory amountsIn = new uint256[](3);
        amountsIn[0] = 0; // bpt index
        amountsIn[1] = 1_000 * 1e18; // AUX amountIn; 1,000 AUX ~= 60.99 USDC
        amountsIn[2] = 61 * 1e6; // USDC amountIn

        IVault.JoinPoolRequest memory req = IVault.JoinPoolRequest({
            assets: _asIAsset(tokens),
            maxAmountsIn: maxAmountsIn,
            userData: abi.encode(StablePoolUserData.JoinKind.INIT, amountsIn),
            fromInternalBalance: false
        });

        _vault.joinPool(csp.getPoolId(), address(this), address(this), req);

        (uint256 cash, , , ) = _vault.getPoolTokenInfo(csp.getPoolId(), IERC20(AUX));
        console2.log("Balancer's AUX Balance:", cash);
        console2.log("Real AUX Balance:\t", IERC20(AUX).balanceOf(address(_vault)));
    }

    function _exitPool(IVault _vault, ComposableStablePool _csp) internal {
        uint256 lpAmount = IERC20(address(_csp)).balanceOf(address(this));
        // this is incorrect, it
        uint256 transferFees = IERC20CustomFee(AUX).getTransferFeeAmount(lpAmount);
        console2.log("_exitPool:: total lpAmount:", lpAmount);
        lpAmount = lpAmount - transferFees;
        console2.log("_exitPool:: lpAmount burn:", lpAmount);
        console2.log("_exitPool:: transfer fee:", transferFees);
        IAsset[] memory tokens = new IAsset[](3);
        tokens[0] = IAsset(address(_csp));
        tokens[1] = IAsset(AUX);
        tokens[2] = IAsset(USDC);

        address[] memory sorted = new address[](3);
        sorted[0] = address(_csp);
        sorted[1] = AUX;
        sorted[2] = USDC;

        bytes memory userData = abi.encode(
            StablePoolUserData.ExitKind.EXACT_BPT_IN_FOR_ALL_TOKENS_OUT,
            lpAmount,
            sorted
        );
        IVault.ExitPoolRequest memory req = IVault.ExitPoolRequest({
            assets: tokens,
            minAmountsOut: _uint256ArrVal(3, 0),
            userData: userData,
            toInternalBalance: false
        });

        IERC20(address(_csp)).approve(address(_vault), type(uint).max);
        _vault.exitPool(_csp.getPoolId(), address(this), payable(address(this)), req);

        uint256 lpAmountLeft = IERC20(address(_csp)).balanceOf(address(this));
        console2.log("_exitPool:: lpAmountLeft:", lpAmountLeft);
    }

    function _setupTokenAllowance(IVault _vault) internal {
        vm.prank(USDC_HOLDER);
        IERC20(USDC).transfer(address(this), 100_000 * 1e6);
        vm.prank(AUX_HOLDER);
        IERC20(AUX).transfer(address(this), 100_000 * 1e18);

        IERC20(USDC).approve(address(_vault), type(uint).max);
        IERC20(AUX).approve(address(_vault), type(uint).max);
    }

    function _sortAssetsList(address _t0, address _t1) internal pure returns (address[] memory) {
        (address t0, address t1) = _sortAssets(_t0, _t1);
        address[] memory sortedTokens = new address[](2);
        sortedTokens[0] = t0;
        sortedTokens[1] = t1;

        return sortedTokens;
    }

    function _uint256ArrVal(uint256 arrSize, uint256 _val) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](arrSize);
        for (uint256 i = 0; i < arrSize; i++) {
            arr[i] = _val;
        }
        return arr;
    }

    function _sortAssets(address _t0, address _t1) internal pure returns (address, address) {
        return _t0 < _t1 ? (_t0, _t1) : (_t1, _t0);
    }
}

interface IERC20CustomFee {
    function getTransferFeeAmount(uint256 amount) external view returns (uint256);
}
