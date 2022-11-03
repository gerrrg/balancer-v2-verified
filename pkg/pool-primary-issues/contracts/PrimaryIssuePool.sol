// Implementation of pool for new issues of security tokens that allows price discovery
// (c) Kallol Borah, 2022
//"SPDX-License-Identifier: BUSL1.1"

pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "@balancer-labs/v2-pool-utils/contracts/BasePool.sol";

import "@balancer-labs/v2-interfaces/contracts/pool-primary/IPrimaryPool.sol";

import "@balancer-labs/v2-solidity-utils/contracts/math/Math.sol";
import "@balancer-labs/v2-solidity-utils/contracts/math/FixedPoint.sol";
import "@balancer-labs/v2-solidity-utils/contracts/helpers/ERC20Helpers.sol";

import "@balancer-labs/v2-interfaces/contracts/vault/IGeneralPool.sol";
import "@balancer-labs/v2-interfaces/contracts/pool-primary/PrimaryPoolUserData.sol";
import "@balancer-labs/v2-interfaces/contracts/solidity-utils/helpers/BalancerErrors.sol";

import "./utils/BokkyPooBahsDateTimeLibrary.sol";

import "./interfaces/IMarketMaker.sol";
import "./interfaces/IPrimaryIssuePoolFactory.sol";

contract PrimaryIssuePool is IPrimaryPool, BasePool, IGeneralPool {

    using PrimaryPoolUserData for bytes;
    using BokkyPooBahsDateTimeLibrary for uint256;
    using FixedPoint for uint256;

    IERC20 private immutable _security;
    IERC20 private immutable _currency;

    // Gerg -- private?
    IPrimaryIssuePoolFactory.FactoryPoolParams factoryPoolParams;

    uint256 private constant _TOTAL_TOKENS = 3; //Security token, Currency token (ie, paired token), Balancer pool token

    uint256 private constant _INITIAL_BPT_SUPPLY = 2**(112) - 1; //setting to max BPT allowed in Vault

    uint256 private immutable _scalingFactorSecurity;
    uint256 private immutable _scalingFactorCurrency;

    uint256 private _minPrice;
    uint256 private _maxPrice;

    uint256 private _MAX_TOKEN_BALANCE;
    uint256 private _cutoffTime;
    uint256 private _startTime;

    uint256 private immutable _securityIndex;
    uint256 private immutable _currencyIndex;
    uint256 private immutable _bptIndex;

    address private _balancerManager;

    struct Params {
        uint256 fee;
        uint256 minPrice;
        uint256 maxPrice;
    }

    event OpenIssue(address indexed security, uint256 openingPrice, uint256 maxPrice, uint256 securityOffered, uint256 cutoffTime);
    event Subscription(address indexed security, address assetIn, string assetName, uint256 amount, address investor, uint256 price);

    constructor(
        IVault vault,
        IPrimaryIssuePoolFactory.FactoryPoolParams memory _factoryPoolParams, // Gerg -- why does this have a leading underscore? 
        uint256 pauseWindowDuration,
        uint256 bufferPeriodDuration,
        address owner
    )
        BasePool(
            vault,
            IVault.PoolSpecialization.GENERAL, // Gerg: TODO -- do you actually need to be general? seems like it could probably be minimal swap info
            _factoryPoolParams.name,
            _factoryPoolParams.symbol,
            _sortTokens(IERC20(_factoryPoolParams.security), IERC20(_factoryPoolParams.currency), this),
            new address[](_TOTAL_TOKENS),
            _factoryPoolParams.swapFeePercentage,
            pauseWindowDuration,
            bufferPeriodDuration,
            owner
        )
    {
        // Gerg -- why save all params in struct but also save all other variables separately?
        factoryPoolParams = _factoryPoolParams;
        // set tokens
        _security = IERC20(factoryPoolParams.security); // Gerg -- why are you doing a storage read? This is already in memory
        _currency = IERC20(factoryPoolParams.currency); // Gerg -- why are you doing a storage read? This is already in memory

        // Set token indexes
        (uint256 securityIndex, uint256 currencyIndex, uint256 bptIndex) = _getSortedTokenIndexes(
            IERC20(factoryPoolParams.security), // Gerg -- why are you doing a storage read? This is already in memory
            IERC20(factoryPoolParams.currency), // Gerg -- why are you doing a storage read? This is already in memory
            this
        );
        _securityIndex = securityIndex;
        _currencyIndex = currencyIndex;
        _bptIndex = bptIndex;

        // set scaling factors
        _scalingFactorSecurity = _computeScalingFactor(IERC20(factoryPoolParams.security)); // Gerg -- why are you doing a storage read? This is already in memory
        _scalingFactorCurrency = _computeScalingFactor(IERC20(factoryPoolParams.currency)); // Gerg -- why are you doing a storage read? This is already in memory

        // set price bounds
        _minPrice = factoryPoolParams.minimumPrice; // Gerg -- why are you doing a storage read? This is already in memory
        _maxPrice = factoryPoolParams.basePrice; // Gerg -- why are you doing a storage read? This is already in memory. Why a difference between maxPrice and basePrice? Unify these names

        // set max total balance of securities
        _MAX_TOKEN_BALANCE = factoryPoolParams.maxAmountsIn; // Gerg -- why are you doing a storage read? This is already in memory

        // set issue time bounds
        _cutoffTime = factoryPoolParams.cutOffTime; // Gerg -- why are you doing a storage read? This is already in memory
        _startTime = block.timestamp;

        //set owner
        _balancerManager = owner; // Gerg -- why store owner separately? Why not just access owner with getOwner()? 
    }

    function getSecurity() external view override returns (IERC20) {
        return _security;
    }

    function getCurrency() external view override returns (IERC20) {
        return _currency;
    }

    function getMinimumPrice() external view override returns(uint256) {
        return _minPrice;
    }

    function getMaximumPrice() external view override returns(uint256) {
        return _maxPrice;
    }

    function getSecurityOffered() external view override returns(uint256) {
        return _MAX_TOKEN_BALANCE;
    }

    function getIssueCutoffTime() external view override returns(uint256) {
        return _cutoffTime;
    }

    function getSecurityIndex() external view override returns (uint256) {
        return _securityIndex;
    }

    function getCurrencyIndex() external view override returns (uint256) {
        return _currencyIndex;
    }

    function getBptIndex() public view override returns (uint256) {
        return _bptIndex;
    }

    function initialize() external {
        bytes32 poolId = getPoolId();
        // Gerg -- add `IVault vault = getVault();`
        // use vault instead of repeated getVault() calls

        (IERC20[] memory tokens, , ) = getVault().getPoolTokens(poolId);
        
        // Gerg -- get rid of this commented lines
        //IAsset[] memory _assets = new IAsset[](_TOTAL_TOKENS);
        //_assets[0] = IAsset(address(_security));
        //_assets[1] = IAsset(address(_currency));

        uint256[] memory _maxAmountsIn = new uint256[](_TOTAL_TOKENS);
        _maxAmountsIn[_securityIndex] = _MAX_TOKEN_BALANCE;
        _maxAmountsIn[_currencyIndex] = Math.div(_MAX_TOKEN_BALANCE, _minPrice, false);
        _maxAmountsIn[_bptIndex] = _INITIAL_BPT_SUPPLY;
        IVault.JoinPoolRequest memory request = IVault.JoinPoolRequest({
            //assets: _assets,
            assets: _asIAsset(tokens),
            maxAmountsIn: _maxAmountsIn,
            userData: abi.encode(PrimaryPoolUserData.JoinKind.INIT, _maxAmountsIn),
            fromInternalBalance: false
        });

        // Gerg -- it's a very unusual pattern to have the pool hold its own tokens. What is your goal here?
        getVault().joinPool(getPoolId(), address(this), address(this), request); // Gerg -- don't call getPoolId() when you have poolId?
        emit OpenIssue(address(_security), _minPrice, _maxPrice, _maxAmountsIn[1], _cutoffTime); // Gerg -- you don't know that securityOffered is at index 1. why is this hard coded?
    }

    function exit() external {
        bytes32 poolId = getPoolId();
        // Gerg -- add `IVault vault = getVault();`
        // use vault instead of repeated getVault() calls
        (IERC20[] memory tokens, , ) = getVault().getPoolTokens(poolId);

        // Gerg -- get rid of this commented lines
        //IAsset[] memory _assets = new IAsset[](2);
        //_assets[0] = IAsset(address(_security));
        //_assets[1] = IAsset(address(_currency));

        uint256[] memory _minAmountsOut = new uint256[](_TOTAL_TOKENS);
        _minAmountsOut[_securityIndex] = 0; // Gerg -- this is already initialized to zero. This line is not needed
        _minAmountsOut[_currencyIndex] = Math.div(_MAX_TOKEN_BALANCE, _maxPrice, false); // Gerg -- how do you know this is the minimum amount out you want? Why not query amount in the pool?
        _minAmountsOut[_bptIndex] = 0; // Gerg -- this is already initialized to zero. This line is not needed
        IVault.ExitPoolRequest memory request = IVault.ExitPoolRequest({
            //assets: _assets,
            assets: _asIAsset(tokens),
            minAmountsOut: _minAmountsOut,
            userData: abi.encode(PrimaryPoolUserData.ExitKind.EMERGENCY_EXACT_BPT_IN_FOR_TOKENS_OUT, _INITIAL_BPT_SUPPLY), // Gerg -- why are you calling this EMERGENCY? Seems like the standard expected use
            toInternalBalance: false
        });
        // Gerg -- it seems like this call will fail unless the pool is paused, but I see no call pausing the pool
        getVault().exitPool(getPoolId(), address(this), payable(_balancerManager), request); // Gerg -- don't call getPoolId() when you have poolId?
    }

    function onSwap(
        SwapRequest memory request,
        uint256[] memory balances,
        uint256 indexIn,
        uint256 indexOut
    ) public override onlyVault(request.poolId) whenNotPaused returns (uint256) {
        // ensure that swap request is not beyond issue's cut off time
        require(BokkyPooBahsDateTimeLibrary.addSeconds(_startTime, _cutoffTime) >= block.timestamp, "TimeLimit Over");
        // ensure that price is within price band
        // Gerg -- ^ where are you ensuring this?

        uint256[] memory scalingFactors = _scalingFactors();
        Params memory params = Params({ fee: getSwapFeePercentage(), minPrice: _minPrice, maxPrice: _maxPrice });

        if (request.kind == IVault.SwapKind.GIVEN_IN) {
            request.amount = _upscale(request.amount, scalingFactors[indexIn]);
            uint256 amountOut = _onSwapIn(request, balances, params);
            return _downscaleDown(amountOut, scalingFactors[indexOut]);
        } else if (request.kind == IVault.SwapKind.GIVEN_OUT) {
            request.amount = _upscale(request.amount, scalingFactors[indexOut]);
            uint256 amountIn = _onSwapOut(request, balances, params);
            return _downscaleUp(amountIn, scalingFactors[indexIn]);
        }
    }

    function _onSwapIn(
        SwapRequest memory request,
        uint256[] memory balances,
        Params memory params
    ) internal returns (uint256) {
        //BPT is only held by the pool manager transferred to it during pool initialization, so no BPT swap is considered
        // Gerg -- ^ why bother using preminted BPT then? The entire point of that design pattern is to swap into BPT.
        if (request.tokenIn == _security) {
            return _swapSecurityIn(request, balances, params);
        } else if (request.tokenIn == _currency) {
            return _swapCurrencyIn(request, balances, params);
        } else {
            _revert(Errors.INVALID_TOKEN);
        }
    }

    // Gerg -- The bulk of the code in _swapSecurityIn and _swapCurrencyIn is identical. This should be one function with arguments for which token is coming in.
    function _swapSecurityIn(
        SwapRequest memory request,
        uint256[] memory balances,
        Params memory params
    ) internal returns (uint256) {
        _require(request.tokenOut == _currency, Errors.INVALID_TOKEN);

        // returning currency for current price of security paid in,
        // but only if new price of security do not go out of price band
        // Gerg -- this if statement doesn't do anything. The previous require has already mandated that this is true
        if (request.tokenOut == _currency) {
            uint256 postPaidSecurityBalance = Math.add(balances[_securityIndex], request.amount);
            uint256 tokenOutAmt = Math.sub(balances[_currencyIndex], balances[_securityIndex].mulDown(balances[_currencyIndex].divDown(postPaidSecurityBalance)));
            uint256 postPaidCurrencyBalance = Math.sub(balances[_currencyIndex], tokenOutAmt);
            
            // Gerg -- I understand that you are checking price bounds here, but this setup is very bad for traders.
            // In the current setup, if a trade goes out of bounds, the pool just takes the traders tokens and gives them nothing
            // This should be a require() instead of an if statement that returns zero if false
            if (
                postPaidCurrencyBalance.divDown(postPaidSecurityBalance) >= params.minPrice &&
                postPaidCurrencyBalance.divDown(postPaidSecurityBalance) <= params.maxPrice
            ){
                //IMarketMaker(_balancerManager).subscribe(getPoolId(), address(_security), address(_security), ERC20(address(_security)).name(), request.amount, request.from, tokenOutAmt, false);
                emit Subscription(address(_security), address(_security), ERC20(address(_security)).name(), request.amount, request.from, tokenOutAmt);
                return tokenOutAmt;
            } 
            else
                return 0;
        }
    }

    function _swapCurrencyIn(
        SwapRequest memory request,
        uint256[] memory balances,
        Params memory params
    ) internal returns (uint256) {
        _require(request.tokenOut == _security, Errors.INVALID_TOKEN);

        // returning security for currency paid in at current price of security,
        // but only if new price of security do not go out of price band
        // Gerg -- this if statement doesn't do anything. The previous require has already mandated that this is true
        if (request.tokenOut == _security) {
            uint256 postPaidCurrencyBalance = Math.add(balances[_currencyIndex], request.amount);
            uint256 tokenOutAmt = Math.sub(balances[_securityIndex], balances[_currencyIndex].mulDown(balances[_securityIndex].divDown(postPaidCurrencyBalance)));
            uint256 postPaidSecurityBalance = Math.sub(balances[_securityIndex], tokenOutAmt);

            // Gerg -- I understand that you are checking price bounds here, but this setup is very bad for traders.
            // In the current setup, if a trade goes out of bounds, the pool just takes the traders tokens and gives them nothing
            // This should be a require() instead of an if statement that returns zero if false
            if (
                postPaidCurrencyBalance.divDown(postPaidSecurityBalance) >= params.minPrice &&
                postPaidCurrencyBalance.divDown(postPaidSecurityBalance) <= params.maxPrice
            ){
                //IMarketMaker(_balancerManager).subscribe(getPoolId(), address(_security), address(_currency), ERC20(address(_currency)).name(), request.amount, request.from, tokenOutAmt, true);
                emit Subscription(address(_security), address(_currency), ERC20(address(_currency)).name(), request.amount, request.from, tokenOutAmt);
                return tokenOutAmt;
            }
            else 
                return 0;
        }
    }

    function _onSwapOut(
        SwapRequest memory request,
        uint256[] memory balances,
        Params memory params
    ) internal returns (uint256) {
        //BPT is only held by the pool manager transferred to it during pool initialization, so no BPT swap is supported
        if (request.tokenOut == _security) {
            return _swapSecurityOut(request, balances, params);
        } else if (request.tokenOut == _currency) {
            return _swapCurrencyOut(request, balances, params);
        } else {
            _revert(Errors.INVALID_TOKEN);
        }
    }
    // Gerg -- The bulk of the code in _swapSecurityOut and _swapCurrencyOut is identical. This should be one function with arguments for which token is coming in.
    function _swapSecurityOut(
        SwapRequest memory request,
        uint256[] memory balances,
        Params memory params
    ) internal returns (uint256) {
        _require(request.tokenIn == _currency, Errors.INVALID_TOKEN);

        //returning security to be swapped out for paid in currency
        // Gerg -- this if statement doesn't do anything. The previous require has already mandated that this is true
        if (request.tokenIn == _currency) {
            uint256 postPaidSecurityBalance = Math.sub(balances[_securityIndex], request.amount);
            uint256 tokenInAmt = Math.sub(balances[_securityIndex].mulDown(balances[_currencyIndex].divDown(postPaidSecurityBalance)), balances[_currencyIndex]);
            uint256 postPaidCurrencyBalance = Math.add(balances[_currencyIndex], tokenInAmt);

            // Gerg -- I understand that you are checking price bounds here, but this setup is very bad for traders.
            // In the current setup, if a trade goes out of bounds, the pool just takes the traders tokens and gives them nothing
            // This should be a require() instead of an if statement that returns zero if false
            if (
                postPaidCurrencyBalance.divDown(postPaidSecurityBalance) >= params.minPrice &&
                postPaidCurrencyBalance.divDown(postPaidSecurityBalance) <= params.maxPrice
            ){
                //IMarketMaker(_balancerManager).subscribe(getPoolId(), address(_security), address(_currency), ERC20(address(_currency)).name(), request.amount, request.from, tokenOutAmt, true);
                emit Subscription(address(_security), address(_currency), ERC20(address(_currency)).name(), request.amount, request.from, tokenInAmt);
                return tokenInAmt;
            }
            else 
                return 0;
        }
    }

    function _swapCurrencyOut(
        SwapRequest memory request,
        uint256[] memory balances,
        Params memory params
    ) internal returns (uint256) {
        _require(request.tokenIn == _security, Errors.INVALID_TOKEN);

        //returning currency to be paid in for security paid in
        // Gerg -- this if statement doesn't do anything. The previous require has already mandated that this is true
        if (request.tokenIn == _security) {
            uint256 postPaidCurrencyBalance = Math.sub(balances[_currencyIndex], request.amount);
            uint256 tokenInAmt = Math.sub(balances[_currencyIndex].mulDown(balances[_securityIndex].divDown(postPaidCurrencyBalance)), balances[_securityIndex]);
            uint256 postPaidSecurityBalance = Math.add(balances[_securityIndex], tokenInAmt);

            // Gerg -- I understand that you are checking price bounds here, but this setup is very bad for traders.
            // In the current setup, if a trade goes out of bounds, the pool just takes the traders tokens and gives them nothing
            // This should be a require() instead of an if statement that returns zero if false
            if (
                postPaidCurrencyBalance.divDown(postPaidSecurityBalance) >= params.minPrice &&
                postPaidCurrencyBalance.divDown(postPaidSecurityBalance) <= params.maxPrice
            ){
                //IMarketMaker(_balancerManager).subscribe(getPoolId(), address(_security), address(_security), ERC20(address(_security)).name(), request.amount, request.from, tokenOutAmt, false);
                emit Subscription(address(_security), address(_security), ERC20(address(_security)).name(), request.amount, request.from, tokenInAmt);
                return tokenInAmt;
            }
            else 
                return 0;
        }
    }

    function _onInitializePool(
        bytes32,
        address sender,
        address recipient,
        uint256[] memory,
        bytes memory
    ) internal view override whenNotPaused returns (uint256, uint256[] memory) {
        //the primary issue pool is initialized by the balancer manager contract
        _require(sender == address(this), Errors.INVALID_INITIALIZATION);
        _require(recipient == address(this), Errors.INVALID_INITIALIZATION);
        
        // Gerg -- why are you minting the max amount of BPT to yourself?
        uint256 bptAmountOut = _INITIAL_BPT_SUPPLY; // Gerg -- why are you hard coding this when it's encoded in your arguments?
        uint256[] memory amountsIn = new uint256[](_TOTAL_TOKENS); // Gerg -- why are your input amounts zero? Your initialize function 
        /* Gerg -- why did you set these in initialize() if you're just passing in zeros?
        _maxAmountsIn[_securityIndex] = _MAX_TOKEN_BALANCE;
        _maxAmountsIn[_currencyIndex] = Math.div(_MAX_TOKEN_BALANCE, _minPrice, false);
        */
        amountsIn[_bptIndex] = _INITIAL_BPT_SUPPLY; // Gerg -- why are you hard coding this when it's encoded in your arguments?

        // Gerg bptAmountOut AND amountsIn are set to _INITIAL_BPT_SUPPLY, which doesn't make sense. What is your goal for the pool's and owner's BPT?

        return (bptAmountOut, amountsIn);
    }

    function _onJoinPool(
        bytes32,
        address,
        address,
        uint256[] memory,
        uint256,
        uint256,
        uint256[] memory,
        bytes memory
    ) internal pure override returns (uint256, uint256[] memory) {
        _revert(Errors.UNHANDLED_BY_PRIMARY_POOL);
    }

    function _onExitPool(
        bytes32,
        address,
        address,
        uint256[] memory balances,
        uint256,
        uint256,
        uint256[] memory,
        bytes memory userData
    ) internal view override returns (uint256 bptAmountIn, uint256[] memory amountsOut) {
        PrimaryPoolUserData.ExitKind kind = userData.exitKind();
        // Gerg -- why if(...){revert()}? why not require(condition,error)?
        if (kind != PrimaryPoolUserData.ExitKind.EMERGENCY_EXACT_BPT_IN_FOR_TOKENS_OUT) {
            //usually exit pool reverts
            _revert(Errors.UNHANDLED_BY_PRIMARY_POOL);
        } else {
            //unless paused in which case tokens are retrievable by contributors
            _ensurePaused();
            (bptAmountIn, amountsOut) = _emergencyProportionalExit(balances, userData);

        }
    }

    function _emergencyProportionalExit(uint256[] memory balances, bytes memory userData)
        private
        view
        returns (uint256, uint256[] memory)
    {
        // This proportional exit function is only enabled if the contract is paused, to provide users a way to
        // retrieve their tokens in case of an emergency.
        uint256 bptAmountIn = userData.exactBptInForTokensOut();
        uint256 bptRatio = Math.div(bptAmountIn, Math.sub(totalSupply(), balances[_bptIndex]), false);
        uint256[] memory amountsOut = new uint256[](balances.length);
        for (uint256 i = 0; i < balances.length; i++) {
            // BPT is skipped as those tokens are not the LPs, but rather the preminted and undistributed amount.
            if (i != _bptIndex) {
                amountsOut[i] = balances[i].mulDown(bptRatio);
            }
        }

        return (bptAmountIn, amountsOut);
    }

    function _getMaxTokens() internal pure override returns (uint256) {
        return _TOTAL_TOKENS;
    }

    function _getTotalTokens() internal view virtual override returns (uint256) {
        return _TOTAL_TOKENS;
    }

    function _scalingFactor(IERC20 token) internal view virtual override returns (uint256) {
        if (token == _security || token == _currency) {
            return FixedPoint.ONE;
        } else {
            _revert(Errors.INVALID_TOKEN);
        }
    }

    function _scalingFactors() internal view virtual override returns (uint256[] memory) {
        uint256[] memory scalingFactors = new uint256[](_TOTAL_TOKENS);
        scalingFactors[_securityIndex] = FixedPoint.ONE;
        scalingFactors[_currencyIndex] = FixedPoint.ONE;
        scalingFactors[_bptIndex] = FixedPoint.ONE;
        return scalingFactors;
    }

    function _getMinimumBpt() internal pure override returns (uint256) {
        // Linear Pools don't lock any BPT, as the total supply will already be forever non-zero due to the preminting
        // mechanism, ensuring initialization only occurs once.
        return 0;
    }
}
