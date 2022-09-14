// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "@balancer-labs/v2-interfaces/contracts/pool-weighted/WeightedPoolUserData.sol";
import "@balancer-labs/v2-interfaces/contracts/vault/IMinimalSwapInfoPool.sol";

import "@balancer-labs/v2-solidity-utils/contracts/math/FixedPoint.sol";
import "@balancer-labs/v2-solidity-utils/contracts/helpers/InputHelpers.sol";

import "../../WeightedMath.sol";

import "./BasePool.sol";

/**
 * @dev Base class for WeightedPools containing swap, join and exit logic, but leaving storage and management of
 * the weights to subclasses. Derived contracts can choose to make weights immutable, mutable, or even dynamic
 *  based on local or external logic.
 */
abstract contract BaseWeightedPool is IMinimalSwapInfoPool, BasePool {
    using FixedPoint for uint256;
    using WeightedPoolUserData for bytes;

    constructor(
        IVault vault,
        string memory name,
        string memory symbol,
        IERC20[] memory tokens,
        address[] memory assetManagers,
        uint256 swapFeePercentage,
        uint256 pauseWindowDuration,
        uint256 bufferPeriodDuration,
        address owner,
        bool mutableTokens
    )
        BasePool(
            vault,
            // Given we support both of these specializations, if this Pool never registers or deregisters any tokens
            // after construction, picking Two Token when the Pool only has two tokens is free gas savings.
            // If the pool is expected to be able register new tokens in future, we must choose MINIMAL_SWAP_INFO
            // as clearly the TWO_TOKEN specification doesn't support adding extra tokens in future.
            tokens.length == 2 && !mutableTokens
                ? IVault.PoolSpecialization.TWO_TOKEN
                : IVault.PoolSpecialization.MINIMAL_SWAP_INFO,
            name,
            symbol,
            tokens,
            assetManagers,
            swapFeePercentage,
            pauseWindowDuration,
            bufferPeriodDuration,
            owner
        )
    {
        // solhint-disable-previous-line no-empty-blocks
    }

    // Virtual functions

    /**
     * @dev Returns the normalized weight of `token`. Weights are fixed point numbers that sum to FixedPoint.ONE.
     */
    function _getNormalizedWeight(IERC20 token) internal view virtual returns (uint256);

    /**
     * @dev Returns all normalized weights, in the same order as the Pool's tokens.
     */
    function _getNormalizedWeights() internal view virtual returns (uint256[] memory);

    /**
     * @dev Returns the current value of the invariant.
     */
    function getInvariant() public view returns (uint256) {
        (, uint256[] memory balances, ) = getVault().getPoolTokens(getPoolId());

        // Since the Pool hooks always work with upscaled balances, we manually
        // upscale here for consistency
        _upscaleArray(balances, _scalingFactors());

        uint256[] memory normalizedWeights = _getNormalizedWeights();
        return WeightedMath._calculateInvariant(normalizedWeights, balances);
    }

    function getNormalizedWeights() external view returns (uint256[] memory) {
        return _getNormalizedWeights();
    }

    // Base Pool handlers

    // Swap Hooks

    function onSwap(
        SwapRequest memory request,
        uint256 balanceTokenIn,
        uint256 balanceTokenOut
    ) public override onlyVault(request.poolId) returns (uint256) {
        _beforeSwapJoinExit();

        uint256 scalingFactorTokenIn = _scalingFactor(request.tokenIn);
        uint256 scalingFactorTokenOut = _scalingFactor(request.tokenOut);

        balanceTokenIn = _upscale(balanceTokenIn, scalingFactorTokenIn);
        balanceTokenOut = _upscale(balanceTokenOut, scalingFactorTokenOut);

        if (request.kind == IVault.SwapKind.GIVEN_IN) {
            // Fees are subtracted before scaling, to reduce the complexity of the rounding direction analysis.
            request.amount = _subtractSwapFeeAmount(request.amount);

            // All token amounts are upscaled.
            request.amount = _upscale(request.amount, scalingFactorTokenIn);

            uint256 amountOut = _onSwapGivenIn(request, balanceTokenIn, balanceTokenOut);

            // amountOut tokens are exiting the Pool, so we round down.
            return _downscaleDown(amountOut, scalingFactorTokenOut);
        } else {
            // All token amounts are upscaled.
            request.amount = _upscale(request.amount, scalingFactorTokenOut);

            uint256 amountIn = _onSwapGivenOut(request, balanceTokenIn, balanceTokenOut);

            // amountIn tokens are entering the Pool, so we round up.
            amountIn = _downscaleUp(amountIn, scalingFactorTokenIn);

            // Fees are added after scaling happens, to reduce the complexity of the rounding direction analysis.
            return _addSwapFeeAmount(amountIn);
        }
    }

    /*
     * @dev Called when a swap with the Pool occurs, where the amount of tokens entering the Pool is known.
     *
     * Returns the amount of tokens that will be taken from the Pool in return.
     *
     * All amounts inside `swapRequest`, `balanceTokenIn`, and `balanceTokenOut` are upscaled. The swap fee has already
     * been deducted from `swapRequest.amount`.
     *
     * The return value is also considered upscaled, and will be downscaled (rounding down) before returning it to the
     * Vault.
     */
    function _onSwapGivenIn(
        SwapRequest memory swapRequest,
        uint256 balanceTokenIn,
        uint256 balanceTokenOut
    ) internal virtual returns (uint256);

    /*
     * @dev Called when a swap with the Pool occurs, where the amount of tokens exiting the Pool is known.
     *
     * Returns the amount of tokens that will be granted to the Pool in return.
     *
     * All amounts inside `swapRequest`, `balanceTokenIn`, and `balanceTokenOut` are upscaled.
     *
     * The return value is also considered upscaled, and will be downscaled (rounding up) before applying the swap fee
     * and returning it to the Vault.
     */
    function _onSwapGivenOut(
        SwapRequest memory swapRequest,
        uint256 balanceTokenIn,
        uint256 balanceTokenOut
    ) internal virtual returns (uint256);

    /**
     * @dev Called before any join or exit operation. Returns the Pool's total supply by default, but derived contracts
     * may choose to add custom behavior at these steps. This often has to do with protocol fee processing.
     */
    function _beforeJoinExit(uint256[] memory preBalances, uint256[] memory normalizedWeights)
        internal
        virtual
        returns (uint256);

    // Join

    function _onJoinPool(
        bytes32,
        address sender,
        address,
        uint256[] memory balances,
        uint256,
        uint256,
        uint256[] memory scalingFactors,
        bytes memory userData
    ) internal virtual override returns (uint256, uint256[] memory) {
        uint256[] memory normalizedWeights = _getNormalizedWeights();

        uint256 preJoinExitSupply = _beforeJoinExit(balances, normalizedWeights);

        (uint256 bptAmountOut, uint256[] memory amountsIn) = _doJoin(
            sender,
            balances,
            normalizedWeights,
            scalingFactors,
            preJoinExitSupply,
            userData
        );

        return (bptAmountOut, amountsIn);
    }

    /**
     * @dev Dispatch code which decodes the provided userdata to perform the specified join type.
     * Inheriting contracts may override this function to add additional join types or extra conditions to allow
     * or disallow joins under certain circumstances.
     */
    function _doJoin(
        address,
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory scalingFactors,
        uint256 totalSupply,
        bytes memory userData
    ) internal view virtual returns (uint256, uint256[] memory) {
        WeightedPoolUserData.JoinKind kind = userData.joinKind();

        if (kind == WeightedPoolUserData.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT) {
            return _joinExactTokensInForBPTOut(balances, normalizedWeights, scalingFactors, totalSupply, userData);
        } else if (kind == WeightedPoolUserData.JoinKind.TOKEN_IN_FOR_EXACT_BPT_OUT) {
            return _joinTokenInForExactBPTOut(balances, normalizedWeights, totalSupply, userData);
        } else if (kind == WeightedPoolUserData.JoinKind.ALL_TOKENS_IN_FOR_EXACT_BPT_OUT) {
            return _joinAllTokensInForExactBPTOut(balances, totalSupply, userData);
        } else {
            _revert(Errors.UNHANDLED_JOIN_KIND);
        }
    }

    function _joinExactTokensInForBPTOut(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory scalingFactors,
        uint256 totalSupply,
        bytes memory userData
    ) private view returns (uint256, uint256[] memory) {
        (uint256[] memory amountsIn, uint256 minBPTAmountOut) = userData.exactTokensInForBptOut();
        InputHelpers.ensureInputLengthMatch(balances.length, amountsIn.length);

        _upscaleArray(amountsIn, scalingFactors);

        uint256 bptAmountOut = WeightedMath._calcBptOutGivenExactTokensIn(
            balances,
            normalizedWeights,
            amountsIn,
            totalSupply,
            getSwapFeePercentage()
        );

        _require(bptAmountOut >= minBPTAmountOut, Errors.BPT_OUT_MIN_AMOUNT);

        return (bptAmountOut, amountsIn);
    }

    function _joinTokenInForExactBPTOut(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256 totalSupply,
        bytes memory userData
    ) private view returns (uint256, uint256[] memory) {
        (uint256 bptAmountOut, uint256 tokenIndex) = userData.tokenInForExactBptOut();
        // Note that there is no maximum amountIn parameter: this is handled by `IVault.joinPool`.

        _require(tokenIndex < balances.length, Errors.OUT_OF_BOUNDS);

        uint256 amountIn = WeightedMath._calcTokenInGivenExactBptOut(
            balances[tokenIndex],
            normalizedWeights[tokenIndex],
            bptAmountOut,
            totalSupply,
            getSwapFeePercentage()
        );

        // We join in a single token, so we initialize amountsIn with zeros
        uint256[] memory amountsIn = new uint256[](balances.length);
        // And then assign the result to the selected token
        amountsIn[tokenIndex] = amountIn;

        return (bptAmountOut, amountsIn);
    }

    function _joinAllTokensInForExactBPTOut(
        uint256[] memory balances,
        uint256 totalSupply,
        bytes memory userData
    ) private pure returns (uint256, uint256[] memory) {
        uint256 bptAmountOut = userData.allTokensInForExactBptOut();
        // Note that there is no maximum amountsIn parameter: this is handled by `IVault.joinPool`.

        uint256[] memory amountsIn = WeightedMath._calcAllTokensInGivenExactBptOut(balances, bptAmountOut, totalSupply);

        return (bptAmountOut, amountsIn);
    }

    // Exit

    function _onExitPool(
        bytes32,
        address sender,
        address,
        uint256[] memory balances,
        uint256,
        uint256,
        uint256[] memory scalingFactors,
        bytes memory userData
    ) internal virtual override returns (uint256, uint256[] memory) {
        uint256[] memory normalizedWeights = _getNormalizedWeights();

        uint256 preJoinExitSupply = _beforeJoinExit(balances, normalizedWeights);

        (uint256 bptAmountIn, uint256[] memory amountsOut) = _doExit(
            sender,
            balances,
            normalizedWeights,
            scalingFactors,
            preJoinExitSupply,
            userData
        );

        return (bptAmountIn, amountsOut);
    }

    /**
     * @dev Dispatch code which decodes the provided userdata to perform the specified exit type.
     * Inheriting contracts may override this function to add additional exit types or extra conditions to allow
     * or disallow exit under certain circumstances.
     */
    function _doExit(
        address,
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory scalingFactors,
        uint256 totalSupply,
        bytes memory userData
    ) internal view virtual returns (uint256, uint256[] memory) {
        WeightedPoolUserData.ExitKind kind = userData.exitKind();

        if (kind == WeightedPoolUserData.ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT) {
            return _exitExactBPTInForTokenOut(balances, normalizedWeights, totalSupply, userData);
        } else if (kind == WeightedPoolUserData.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT) {
            return _exitExactBPTInForTokensOut(balances, totalSupply, userData);
        } else if (kind == WeightedPoolUserData.ExitKind.BPT_IN_FOR_EXACT_TOKENS_OUT) {
            return _exitBPTInForExactTokensOut(balances, normalizedWeights, scalingFactors, totalSupply, userData);
        } else {
            _revert(Errors.UNHANDLED_EXIT_KIND);
        }
    }

    function _exitExactBPTInForTokenOut(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256 totalSupply,
        bytes memory userData
    ) private view returns (uint256, uint256[] memory) {
        (uint256 bptAmountIn, uint256 tokenIndex) = userData.exactBptInForTokenOut();
        // Note that there is no minimum amountOut parameter: this is handled by `IVault.exitPool`.

        _require(tokenIndex < balances.length, Errors.OUT_OF_BOUNDS);

        uint256 amountOut = WeightedMath._calcTokenOutGivenExactBptIn(
            balances[tokenIndex],
            normalizedWeights[tokenIndex],
            bptAmountIn,
            totalSupply,
            getSwapFeePercentage()
        );

        // This is an exceptional situation in which the fee is charged on a token out instead of a token in.
        // We exit in a single token, so we initialize amountsOut with zeros
        uint256[] memory amountsOut = new uint256[](balances.length);
        // And then assign the result to the selected token
        amountsOut[tokenIndex] = amountOut;

        return (bptAmountIn, amountsOut);
    }

    function _exitExactBPTInForTokensOut(
        uint256[] memory balances,
        uint256 totalSupply,
        bytes memory userData
    ) private pure returns (uint256, uint256[] memory) {
        uint256 bptAmountIn = userData.exactBptInForTokensOut();
        // Note that there is no minimum amountOut parameter: this is handled by `IVault.exitPool`.

        uint256[] memory amountsOut = WeightedMath._calcTokensOutGivenExactBptIn(balances, bptAmountIn, totalSupply);
        return (bptAmountIn, amountsOut);
    }

    function _exitBPTInForExactTokensOut(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory scalingFactors,
        uint256 totalSupply,
        bytes memory userData
    ) private view returns (uint256, uint256[] memory) {
        (uint256[] memory amountsOut, uint256 maxBPTAmountIn) = userData.bptInForExactTokensOut();
        InputHelpers.ensureInputLengthMatch(amountsOut.length, balances.length);
        _upscaleArray(amountsOut, scalingFactors);

        // This is an exceptional situation in which the fee is charged on a token out instead of a token in.
        uint256 bptAmountIn = WeightedMath._calcBptInGivenExactTokensOut(
            balances,
            normalizedWeights,
            amountsOut,
            totalSupply,
            getSwapFeePercentage()
        );
        _require(bptAmountIn <= maxBPTAmountIn, Errors.BPT_IN_MAX_AMOUNT);

        return (bptAmountIn, amountsOut);
    }
}
