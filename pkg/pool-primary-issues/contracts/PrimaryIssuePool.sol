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

    uint256 private constant _TOTAL_TOKENS = 3; //Security token, Currency token (ie, paired token), Balancer pool token

    uint256 private constant _INITIAL_BPT_SUPPLY = 2**(112) - 1; //setting to max BPT allowed in Vault

    uint256 private immutable _scalingFactorSecurity;
    uint256 private immutable _scalingFactorCurrency;

    // GERG: these should all be immutable. instead of emitting these in OpenIssue, emit the things you are assigning to these. See comments below for _MAX_TOKEN_BALANCE
    uint256 private _minPrice;
    uint256 private _maxPrice;

    // GERG: these should all be immutable. instead of emitting these in OpenIssue, emit the things you are assigning to these. See comments below for _MAX_TOKEN_BALANCE
    uint256 private _MAX_TOKEN_BALANCE;
    uint256 private _cutoffTime;
    uint256 private _startTime;
    string private _offeringDocs;

    uint256 private immutable _securityIndex;
    uint256 private immutable _currencyIndex;
    uint256 private immutable _bptIndex;

    // GERG: this should be immutable
    address private _balancerManager;

    struct Params {
        uint256 fee;
        uint256 minPrice;
        uint256 maxPrice;
    }

    event OpenIssue(address indexed security, uint256 openingPrice, uint256 maxPrice, uint256 securityOffered, uint256 cutoffTime, string offeringDocs);
    event Subscription(address indexed security, address assetIn, string assetName, uint256 amount, address investor, uint256 price);

    constructor(
        IVault vault,
        IPrimaryIssuePoolFactory.FactoryPoolParams memory factoryPoolParams,
        uint256 pauseWindowDuration,
        uint256 bufferPeriodDuration,
        address owner
    )
        BasePool(
            vault,
            IVault.PoolSpecialization.GENERAL,
            factoryPoolParams.name,
            factoryPoolParams.symbol,
            _sortTokens(IERC20(factoryPoolParams.security), IERC20(factoryPoolParams.currency), this),
            new address[](_TOTAL_TOKENS), // GERG: why are you reading _TOTAL_TOKENS directly if you wrote a getter?
            factoryPoolParams.swapFeePercentage,
            pauseWindowDuration,
            bufferPeriodDuration,
            owner
        )
    {
        // set tokens
        _security = IERC20(factoryPoolParams.security);
        _currency = IERC20(factoryPoolParams.currency);

        // Set token indexes
        (uint256 securityIndex, uint256 currencyIndex, uint256 bptIndex) = _getSortedTokenIndexes(
            IERC20(factoryPoolParams.security),
            IERC20(factoryPoolParams.currency),
            this
        );
        _securityIndex = securityIndex;
        _currencyIndex = currencyIndex;
        _bptIndex = bptIndex;

        // set scaling factors
        _scalingFactorSecurity = _computeScalingFactor(IERC20(factoryPoolParams.security));
        _scalingFactorCurrency = _computeScalingFactor(IERC20(factoryPoolParams.currency));

        // set price bounds
        _minPrice = factoryPoolParams.minimumPrice;
        _maxPrice = factoryPoolParams.basePrice;

        // set max total balance of securities
        // GERG: make _MAX_TOKEN_BALANCE immutable and emit factoryPoolParams.maxAmountsIn instead of _MAX_TOKEN_BALANCE in OpenIssue
        _MAX_TOKEN_BALANCE = factoryPoolParams.maxAmountsIn;

        // set issue time bounds
        _cutoffTime = factoryPoolParams.cutOffTime;
        _startTime = block.timestamp;

        //ipfs address of offering docs
        _offeringDocs = factoryPoolParams.offeringDocs;

        //set owner
        _balancerManager = owner;     

        emit OpenIssue(factoryPoolParams.security, _minPrice, _maxPrice, _MAX_TOKEN_BALANCE, _cutoffTime, _offeringDocs);
    }

    // GERG: for all of these getters, why not make them public instead of external, and then use the getters instead of directly accessing your private variables?
    // This would be a much safer way to access these variables. 
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

    function getOfferingDocuments() public view returns(string memory){
        return _offeringDocs;
    }

    function onSwap(
        SwapRequest memory request,
        uint256[] memory balances,
        uint256 indexIn,
        uint256 indexOut
    ) public override onlyVault(request.poolId) whenNotPaused returns (uint256) {
        // ensure that swap request is not beyond issue's cut off time
        require(BokkyPooBahsDateTimeLibrary.addSeconds(_startTime, _cutoffTime) >= block.timestamp, "TimeLimit Over");
        
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
        
        if (request.tokenIn == _security) {
            return _swapSecurityIn(request, balances, params);
        } else if (request.tokenIn == _currency) {
            return _swapCurrencyIn(request, balances, params);
        } else {
            _revert(Errors.INVALID_TOKEN);
        }
    }

    // GERG: these functions can and likely should be unified and optimized. see note below about _swapGivenOut.
    function _swapSecurityIn(
        SwapRequest memory request,
        uint256[] memory balances,
        Params memory params
    ) internal returns (uint256) {
        _require(request.tokenOut == _currency, Errors.INVALID_TOKEN);

        // returning currency for current price of security paid in,
        // but only if new price of security do not go out of price band
        uint256 postPaidSecurityBalance = Math.add(balances[_securityIndex], request.amount);
        uint256 tokenOutAmt = Math.sub(balances[_currencyIndex], balances[_securityIndex].mulDown(balances[_currencyIndex].divDown(postPaidSecurityBalance)));
        uint256 postPaidCurrencyBalance = Math.sub(balances[_currencyIndex], tokenOutAmt);
        
        // GERG: you are not validating that tokenOutAmt < balances[_currencyIndex]. you should definitely do that.
        
        require (postPaidCurrencyBalance.divDown(postPaidSecurityBalance) >= params.minPrice && postPaidCurrencyBalance.divDown(postPaidSecurityBalance) <= params.maxPrice, "Price out of bound");
        //IMarketMaker(_balancerManager).subscribe(getPoolId(), address(_security), address(_security), ERC20(address(_security)).name(), request.amount, request.from, tokenOutAmt, false);
        emit Subscription(address(_security), address(_security), ERC20(address(_security)).name(), request.amount, request.from, tokenOutAmt);
        return tokenOutAmt;        
    }

    // GERG: these functions can and likely should be unified and optimized. see note below about _swapGivenOut.
    function _swapCurrencyIn(
        SwapRequest memory request,
        uint256[] memory balances,
        Params memory params
    ) internal returns (uint256) {
        _require(request.tokenOut == _security, Errors.INVALID_TOKEN);

        // returning security for currency paid in at current price of security,
        // but only if new price of security do not go out of price band
        uint256 postPaidCurrencyBalance = Math.add(balances[_currencyIndex], request.amount);
        uint256 tokenOutAmt = Math.sub(balances[_securityIndex], balances[_currencyIndex].mulDown(balances[_securityIndex].divDown(postPaidCurrencyBalance)));
        uint256 postPaidSecurityBalance = Math.sub(balances[_securityIndex], tokenOutAmt);

        // GERG: you are not validating that tokenOutAmt < balances[_securityIndex]. you should definitely do that.

        require(postPaidCurrencyBalance.divDown(postPaidSecurityBalance) >= params.minPrice && postPaidCurrencyBalance.divDown(postPaidSecurityBalance) <= params.maxPrice, "Price out of bound");
        //IMarketMaker(_balancerManager).subscribe(getPoolId(), address(_security), address(_currency), ERC20(address(_currency)).name(), request.amount, request.from, tokenOutAmt, true);
        emit Subscription(address(_security), address(_currency), ERC20(address(_currency)).name(), request.amount, request.from, tokenOutAmt);
        return tokenOutAmt;
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

    // GERG: _swapSecurityOut and _swapCurrencyOut are nearly identical and each do a ton of storage reads. Similarly, so do _swapSecurityIn and _swapCurrencyIn.
    // This is inefficient both for gas and bytecode. This should be written to something that both generalizes the code and minimizes the number of storage reads.
    // Below is an example snippet for _swap*Out. I would recommend a similar structure for _swap*In. Additionally, these four functions could potentially even be 
    // unified into one single function, but I have not deeply examined if this is possible/feasible/easy. The below snippet **HAS NOT BEEN TESTED AT ALL** and 
    // should be considered only pseudocode. You should use it only as an example of what I am suggesting.
    /*
    function _swapGivenOut(
        SwapRequest memory request,
        uint256[] memory balances,
        Params memory params
    ) internal returns (uint256) {

        uint256 inputIndex;
        uint256 outputIndex;
        address input;
        address output;
        address currency =_currency;
        address security =_security;
        bool isCurrencyOut;

        if (request.tokenIn == currency && request.tokenOut == security) {
            inputIndex = _currencyIndex;
            outputIndex = _securityIndex;
            input = currency;
            output = security;
            // isCurrencyOut = false; //default false, no need to rewrite.
        } else if (request.tokenIn == security && request.tokenOut == currency ) {
            inputIndex = _securityIndex;
            outputIndex = _currencyIndex;
            input = security;
            output = currency;
            isCurrencyOut = true;
        } else {
            revert(Errors.INVALID_TOKEN);
        }
        require(request.amount < balances[outputIndex], "Insufficient balance");

        //returning security to be swapped out for paid in currency
        uint256 postPaidOutputBalance = Math.sub(balances[outputIndex], request.amount);
        uint256 tokenInAmt = Math.sub(balances[outputIndex].mulDown(balances[inputIndex].divDown(postPaidSecurityBalance)), balances[inputIndex]);
        uint256 postPaidInputBalance = Math.add(balances[inputIndex], tokenInAmt);

        uint256 postPaidCurrencyBalance;
        uint256 postPaidSecurityBalance;
        if (isCurrencyOut) {
            postPaidCurrencyBalance = postPaidInputBalance;
            postPaidSecurityBalance = postPaidOutputBalance;
        }
        require(postPaidCurrencyBalance.divDown(postPaidSecurityBalance) >= params.minPrice && postPaidCurrencyBalance.divDown(postPaidSecurityBalance) <= params.maxPrice, "Price out of bound");
        emit Subscription(address(security), address(input), ERC20(address(input)).name(), request.amount, request.from, tokenInAmt);
        return tokenInAmt;
    }
    */

    function _swapSecurityOut(
        SwapRequest memory request,
        uint256[] memory balances,
        Params memory params
    ) internal returns (uint256) {
        _require(request.tokenIn == _currency, Errors.INVALID_TOKEN);
        require(request.amount < balances[_securityIndex], "Insufficient balance");

        //returning security to be swapped out for paid in currency
        uint256 postPaidSecurityBalance = Math.sub(balances[_securityIndex], request.amount);
        uint256 tokenInAmt = Math.sub(balances[_securityIndex].mulDown(balances[_currencyIndex].divDown(postPaidSecurityBalance)), balances[_currencyIndex]);
        uint256 postPaidCurrencyBalance = Math.add(balances[_currencyIndex], tokenInAmt);

        require(postPaidCurrencyBalance.divDown(postPaidSecurityBalance) >= params.minPrice && postPaidCurrencyBalance.divDown(postPaidSecurityBalance) <= params.maxPrice, "Price out of bound");
        //IMarketMaker(_balancerManager).subscribe(getPoolId(), address(_security), address(_currency), ERC20(address(_currency)).name(), request.amount, request.from, tokenInAmt, true);
        emit Subscription(address(_security), address(_currency), ERC20(address(_currency)).name(), request.amount, request.from, tokenInAmt);
        return tokenInAmt;
    }

    function _swapCurrencyOut(
        SwapRequest memory request,
        uint256[] memory balances,
        Params memory params
    ) internal returns (uint256) {
        _require(request.tokenIn == _security, Errors.INVALID_TOKEN);
        require(request.amount < balances[_currencyIndex], "Insufficient balance");

        //returning currency to be paid in for security paid in
        uint256 postPaidCurrencyBalance = Math.sub(balances[_currencyIndex], request.amount);
        uint256 tokenInAmt = Math.sub(balances[_currencyIndex].mulDown(balances[_securityIndex].divDown(postPaidCurrencyBalance)), balances[_securityIndex]);
        uint256 postPaidSecurityBalance = Math.add(balances[_securityIndex], tokenInAmt);

        require(postPaidCurrencyBalance.divDown(postPaidSecurityBalance) >= params.minPrice && postPaidCurrencyBalance.divDown(postPaidSecurityBalance) <= params.maxPrice, "Price out of bound");
        //IMarketMaker(_balancerManager).subscribe(getPoolId(), address(_security), address(_security), ERC20(address(_security)).name(), request.amount, request.from, tokenInAmt, false);
        emit Subscription(address(_security), address(_security), ERC20(address(_security)).name(), request.amount, request.from, tokenInAmt);
        return tokenInAmt;
    }

    // GERG: everything after this comment appears to be identical to the code at the bottom of SecondaryIssuePool.sol. Why not inherit this functionality so you don't need to write it twice?
    // It would also make cleaning up these functions much easier. 
    function _onInitializePool(
        bytes32,
        address sender,
        address recipient,
        uint256[] memory,
        bytes memory userData
    ) internal view override whenNotPaused returns (uint256, uint256[] memory) {
        //the primary issue pool is initialized by the balancer manager contract
        // GERG: make a local copy of `address balancerManager = _balancerManager;` to decrease your storage reads.
        _require(sender == _balancerManager, Errors.INVALID_INITIALIZATION);
        _require(recipient == payable(_balancerManager), Errors.INVALID_INITIALIZATION);

        uint256 bptAmountOut = _INITIAL_BPT_SUPPLY;
        uint256[] memory amountsIn = userData.joinKind();

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
        if (kind != PrimaryPoolUserData.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT) {
            //usually exit pool reverts
            _revert(Errors.UNHANDLED_BY_PRIMARY_POOL);
        } else {
            // GERG: this is not an emergency use case; this is the expected use. I recommend you rename it accordingly to avoid confusion.
            // GERG: additionally, do you want to enforce some check that the manager is indeed removing *all* of the tokens? if not that's ok, just a thought.
            (bptAmountIn, amountsOut) = _emergencyProportionalExit(balances, userData);
        }
    }

    // GERG: this is not an emergency use case; this is the expected use. I recommend you rename it accordingly to avoid confusion.
    function _emergencyProportionalExit(uint256[] memory balances, bytes memory userData)
        private
        view
        returns (uint256, uint256[] memory)
    {   
        // This proportional exit function is only enabled if the contract is paused, to provide users a way to
        // retrieve their tokens in case of an emergency.
        uint256 bptAmountIn = userData.exactBptInForTokensOut();
        uint256[] memory amountsOut = new uint256[](balances.length);
        for (uint256 i = 0; i < balances.length; i++) {
            // BPT is skipped as those tokens are not the LPs, but rather the preminted and undistributed amount.
            if (i != _bptIndex) {
                amountsOut[i] = balances[i];
            }
        }

        return (bptAmountIn, amountsOut);
    }

    // GERG: why are _getMaxTokens and _getTotalTokens identical except one is pure and the other is view virtual? also neither of these are being used
    function _getMaxTokens() internal pure override returns (uint256) {
        return _TOTAL_TOKENS;
    }

    // GERG: why are _getMaxTokens and _getTotalTokens identical except one is pure and the other is view virtual? also neither of these are being used
    function _getTotalTokens() internal view virtual override returns (uint256) {
        return _TOTAL_TOKENS;
    }

    // GERG: based on the _scalingFactors function below, shouldn't this also have `|| token == _bpt` in the allowable set?
    function _scalingFactor(IERC20 token) internal view virtual override returns (uint256) {
        if (token == _security || token == _currency) {
            return FixedPoint.ONE;
        } else {
            _revert(Errors.INVALID_TOKEN);
        }
    }

    // GERG: this function is gas inefficient. it does 4 storage reads and only needs to do 1.
    // GERG: also why are you reading _TOTAL_TOKENS directly if you wrote a (actually, two) getter(s)?

    // uint256 numTokens = _getMaxTokens();
    // uint256[] memory scalingFactors = new uint256[](numTokens);
    // for(uint256 i = 0; i < numTokens; i++) {
    //    scalingFactors[i] = FixedPoint.ONE;
    // }
    // return scalingFactors
    function _scalingFactors() internal view virtual override returns (uint256[] memory) {
        uint256[] memory scalingFactors = new uint256[](_TOTAL_TOKENS);
        scalingFactors[_securityIndex] = FixedPoint.ONE;
        scalingFactors[_currencyIndex] = FixedPoint.ONE;
        scalingFactors[_bptIndex] = FixedPoint.ONE;
        return scalingFactors;
    }
}
