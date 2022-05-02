// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma abicoder v2;

import "./external/openzeppelin/access/Ownable.sol";
import "./external/openzeppelin/utils/ReentrancyGuard.sol";
import "./external/openzeppelin/utils/Multicall.sol";
import "./external/openzeppelin/token/ERC20/SafeERC20.sol";
import { SafeMath } from "./external/openzeppelin/math/SafeMath.sol";

import "./external/uniswap/v3-core/interfaces/pool/IUniswapV3PoolState.sol";
import "./external/uniswap/v3-core/libraries/TickMath.sol";

import "./external/uniswap/v3-periphery/libraries/LiquidityAmounts.sol";
import "./external/uniswap/v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "./IContract.sol";

import "hardhat/console.sol";

contract Contract is IContract, ReentrancyGuard, Ownable, Multicall {

    using SafeMath for uint256;

    uint128 constant EXP_64 = 2**64;
    uint128 constant EXP_96 = 2**96;

    // max bonus
    uint64 constant public MAX_BONUS_X64 = uint64(EXP_64 / 20); // 5%

    address override public weth;
    IUniswapV3Factory override public factory;
    INonfungiblePositionManager override public nonfungiblePositionManager;
    ISwapRouter override public swapRouter;

    // initial bonus - can be changed from owner
    uint64 public totalBonusX64 = MAX_BONUS_X64; // 5%
    uint64 public compounderBonusX64 = MAX_BONUS_X64 / 5; // 1%
    uint64 public minSwapRatioX64 = uint64(EXP_64 / 20); // 5%
    uint64 public minSwapPriceChangeX64 = uint64(EXP_64 / 20); // 5%

    mapping(uint256 => address) public override ownerOf;
    mapping(address => uint256[]) public userTokens;
    mapping(address => mapping(address => uint256)) public userBalances;

    constructor(address _weth, IUniswapV3Factory _factory, INonfungiblePositionManager _nonfungiblePositionManager, ISwapRouter _swapRouter) {
        weth = _weth;
        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        swapRouter = _swapRouter;
    }

    /**
     * @notice Main method to handle adding NFTs to the protocol
     */
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override nonReentrant returns (bytes4) {
        require(msg.sender == address(nonfungiblePositionManager), "!univ3");

        _addToken(tokenId, from, true);
        emit TokenDeposited(from, tokenId);
        return this.onERC721Received.selector;
    }

    /**
     * @notice Returns amount of NFTs for a given account
     */
    function balanceOf(address account) override external view returns (uint256 length) {
        return userTokens[account].length;
    }

    // state used during autocompound execution
    struct AutoCompoundState {
        uint256 amount0;
        uint256 amount1;
        uint256 maxAddAmount0;
        uint256 maxAddAmount1;
        uint256 amountAdded0;
        uint256 amountAdded1;
        uint256 amount0Fees;
        uint256 amount1Fees;
        address tokenOwner;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
    }

    /**
     * @notice Autocompounds for a given token (anyone can call this and get credited fee tokens)
     * @param params Specifies how autocompound should be done
     */
    function autoCompound(AutoCompoundParams calldata params) override external nonReentrant returns (uint256 bonus0, uint256 bonus1) {

        AutoCompoundState memory state;

        // collect fees
        (state.amount0, state.amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(params.tokenId, address(this), type(uint128).max, type(uint128).max)
        );

        // get position info
        (, , state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, , , , , ) = nonfungiblePositionManager.positions(params.tokenId);
        state.tokenOwner = ownerOf[params.tokenId];

        // add previous balances from given tokens
        state.amount0 = state.amount0.add(userBalances[state.tokenOwner][state.token0]);
        state.amount1 = state.amount1.add(userBalances[state.tokenOwner][state.token1]);

        // if there are no balances to work with - stop here
        if (state.amount0 == 0 && state.amount1 == 0) {
            return (0, 0);
        }

        // swap to position ratio
        (state.amount0, state.amount1) = _swapToPriceRatio(state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, state.amount0, state.amount1, params.deadline);

        // max amount to add considering fees (if token owner is calling - no fees)
        state.maxAddAmount0 = state.tokenOwner == msg.sender ? state.amount0 : state.amount0 * EXP_64 / (EXP_64 + totalBonusX64);
        state.maxAddAmount1 = state.tokenOwner == msg.sender ? state.amount1 : state.amount1 * EXP_64 / (EXP_64 + totalBonusX64);

        // avoid rounding to 0 for very small amounts
        if (state.amount0 > 0 && state.maxAddAmount0 == 0 || state.amount1 > 0 && state.maxAddAmount1 == 0) {
            return (0, 0);
        }

        // deposit liquidity into tokenId
        (, state.amountAdded0, state.amountAdded1) = nonfungiblePositionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams(
                params.tokenId,
                state.maxAddAmount0,
                state.maxAddAmount1,
                0,
                0,
                params.deadline
            )
        );

        // fees only when not tokenOwner
        if (state.tokenOwner != msg.sender) {
            state.amount0Fees = state.amountAdded0 * totalBonusX64 / EXP_64;
            state.amount1Fees = state.amountAdded1 * totalBonusX64 / EXP_64;
        }

        // calculate remaining tokens for owner
        userBalances[state.tokenOwner][state.token0] = state.amount0.sub(state.amountAdded0).sub(state.amount0Fees);
        userBalances[state.tokenOwner][state.token1] = state.amount1.sub(state.amountAdded1).sub(state.amount1Fees);

        // convert fees to token of choice (TODO add optimisation in _swapToPriceRatio formula to do this directly - save one swap)
        if (params.bonusConversion == BonusConversion.TOKEN_0) {
            if (state.amount1Fees > 0) {
                uint256 output = _swap(abi.encodePacked(state.token1, state.fee, state.token0), state.amount1Fees, params.deadline);
                state.amount0Fees = state.amount0Fees.add(output);
                state.amount1Fees = 0;
            }
        } else if (params.bonusConversion == BonusConversion.TOKEN_1) {
            if (state.amount0Fees > 0) {
                uint256 output = _swap(abi.encodePacked(state.token0, state.fee, state.token1), state.amount0Fees, params.deadline);
                state.amount1Fees = state.amount1Fees.add(output);
                state.amount0Fees = 0;
            }
        }

        // distribute fees -  handle 3 cases (contract owner / nft owner / oneone else)
        if (owner() == msg.sender) {
            userBalances[msg.sender][state.token0] = userBalances[msg.sender][state.token0].add(state.amount0Fees);
            userBalances[msg.sender][state.token1] = userBalances[msg.sender][state.token1].add(state.amount1Fees);

            bonus0 = state.amount0Fees;
            bonus1 = state.amount1Fees;
        } else if (state.tokenOwner == msg.sender) {
            bonus0 = 0;
            bonus1 = 0;
        } else {
            uint256 compounderFees0 = state.amount0Fees * compounderBonusX64 / EXP_64;
            uint256 compounderFees1 = state.amount1Fees * compounderBonusX64 / EXP_64;

            userBalances[msg.sender][state.token0] = userBalances[msg.sender][state.token0].add(compounderFees0);
            userBalances[msg.sender][state.token1] = userBalances[msg.sender][state.token1].add(compounderFees1);
            userBalances[owner()][state.token0] = userBalances[owner()][state.token0].add(state.amount0Fees.sub(compounderFees0));
            userBalances[owner()][state.token1] = userBalances[owner()][state.token1].add(state.amount1Fees.sub(compounderFees1));

            bonus0 = compounderFees0;
            bonus1 = compounderFees1;
        }

        if (params.withdrawBonus) {
            withdrawFullBalances(state.token0, state.token1, msg.sender);
        }

        emit AutoCompounded(msg.sender, params.tokenId, state.amountAdded0, state.amountAdded1, bonus0, bonus1);
    }

    // state used during autocompound execution
    struct SwapState {
        uint256 positionAmount0;
        uint256 positionAmount1;
        uint256 priceX96;
        uint160 sqrtPriceX96;
        uint160 sqrtPriceX96Lower;
        uint160 sqrtPriceX96Upper;
        uint256 amountRatioX96;
        uint256 delta0;
        uint256 delta1;
        bool sell0;
        uint256 total0;
    }

    function _swapToPriceRatio(address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1, uint256 deadline) internal returns (uint256, uint256) {
        
        SwapState memory state;
        
        // get price
        IUniswapV3PoolState pool = IUniswapV3PoolState(factory.getPool(token0, token1, fee));

        (state.sqrtPriceX96,,,,,,) = pool.slot0();

        // calculate position amounts
        state.sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(tickLower);
        state.sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(tickUpper);
        (state.positionAmount0, state.positionAmount1) = LiquidityAmounts.getAmountsForLiquidity(state.sqrtPriceX96, state.sqrtPriceX96Lower, state.sqrtPriceX96Upper, EXP_96); // dummy value

        state.priceX96 = (uint256(state.sqrtPriceX96) ** 2) / EXP_96;

        if (state.positionAmount0 == 0) {
            state.delta0 = amount0;
            state.sell0 = true;
        } else if (state.positionAmount1 == 0) {
            state.delta0 = amount1.mul(EXP_96).div(state.priceX96);
            state.sell0 = false;
        } else {
            state.amountRatioX96 = state.positionAmount0.mul(EXP_96).div(state.positionAmount1);
            state.sell0 = (state.amountRatioX96.mul(amount1) < amount0.mul(EXP_96));
            if (state.sell0) {
                state.delta0 = amount0.mul(EXP_96).sub(state.amountRatioX96.mul(amount1)).div(state.amountRatioX96.mul(state.priceX96).div(EXP_96).add(EXP_96));
            } else {
                state.delta0 = state.amountRatioX96.mul(amount1).sub(amount0.mul(EXP_96)).div(state.amountRatioX96.mul(state.priceX96).div(EXP_96).add(EXP_96));
            }
        }
        state.total0 = amount0.add(amount1.mul(EXP_96).div(state.priceX96));

        // only swap when swap big enough
        if (state.delta0.mul(EXP_64).div(state.total0) >= minSwapRatioX64) {
            if (state.sell0) {
                uint256 amountOut = _swap(abi.encodePacked(token0, fee, token1), state.delta0, deadline);
                amount0 = amount0.sub(state.delta0);
                amount1 = amount1.add(amountOut);
            } else {
                state.delta1 = state.delta0 * state.priceX96 / EXP_96;
                uint256 amountOut = _swap(abi.encodePacked(token1, fee, token0), state.delta1, deadline);
                amount0 = amount0.add(amountOut);
                amount1 = amount1.sub(state.delta1);
            }
        }

        return (amount0, amount1);
    }

    /**
     * @notice Management method to lower fees or change ratio between total and compounder fees
     */
    function setBonus(uint64 _totalBonusX64, uint64 _compounderBonusX64) external onlyOwner {
        require(_totalBonusX64 <= totalBonusX64, ">previoustotal");
        require(_compounderBonusX64 <= _totalBonusX64, "compounder>total");
        totalBonusX64 = _totalBonusX64;
        compounderBonusX64 = _compounderBonusX64;
        emit BonusUpdated(msg.sender, _totalBonusX64, _compounderBonusX64);
    }

    /**
     * @notice Management method to change the min ratio to decide when a swap is executed
     */
    function setMinSwapRatio(uint64 _minSwapRatioX64) external onlyOwner {
        minSwapRatioX64 = _minSwapRatioX64;
        emit MinSwapRatioUpdated(msg.sender, _minSwapRatioX64);
    }

    function _swap(bytes memory swapPath, uint256 amount, uint256 deadline) internal returns (uint256 amountOut) {
        amountOut = swapRouter.exactInput(
            ISwapRouter.ExactInputParams(swapPath, address(this), deadline, amount, 0)
        );
    }

    function _addToken(uint256 tokenId, address account, bool checkApprovals) internal {

        // get tokens for this nft
        (, , address token0, address token1, , , , , , , , ) = nonfungiblePositionManager.positions(tokenId);

        if (checkApprovals) {
            _checkApprovals(IERC20(token0), IERC20(token1));
        }

        userTokens[account].push(tokenId);
        ownerOf[tokenId] = account;
    }

    function _checkApprovals(IERC20 token0, IERC20 token1) internal {
        // approve tokens if not yet approved
        uint256 allowance0 = token0.allowance(address(this), address(nonfungiblePositionManager));
        if (allowance0 == 0) {
            SafeERC20.safeApprove(token0, address(nonfungiblePositionManager), type(uint256).max);
            SafeERC20.safeApprove(token0, address(swapRouter), type(uint256).max);
        }
        uint256 allowance1 = token1.allowance(address(this), address(nonfungiblePositionManager));
        if (allowance1 == 0) {
            SafeERC20.safeApprove(token1, address(nonfungiblePositionManager), type(uint256).max);
            SafeERC20.safeApprove(token1, address(swapRouter), type(uint256).max);
        }
    }

    function _removeToken(address account, uint256 tokenId) internal {
        uint256[] memory userTokensArr = userTokens[account];
        uint256 len = userTokensArr.length;
        uint256 assetIndex = len;

        for (uint256 i = 0; i < len; i++) {
            if (userTokensArr[i] == tokenId) {
                assetIndex = i;
                break;
            }
        }

        assert(assetIndex < len);

        uint256[] storage storedList = userTokens[account];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        delete ownerOf[tokenId];
    }

    /**
     * @notice Creates a new position wrapped in a NFT - swaps to the correct ratio and adds it to be autocompounded
     */
    function mintAndSwap(MintAndSwapParams calldata params) external payable override nonReentrant
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        require(params.token0 != params.token1, "token0=token1");

        // wrap ether sent
        if (msg.value > 0) {
            (bool success,) = payable(weth).call{ value: msg.value }("");
            require(success, "wrap eth fail");
        }

        // get missing tokens
        IERC20(params.token0).transferFrom(msg.sender, address(this), (weth == params.token0 ? params.amount0.sub(msg.value) : params.amount0));
        IERC20(params.token1).transferFrom(msg.sender, address(this), (weth == params.token1 ? params.amount1.sub(msg.value) : params.amount1));

        _checkApprovals(IERC20(params.token0), IERC20(params.token1));
        
        (uint256 swappedAmount0, uint256 swappedAmount1) = _swapToPriceRatio(params.token0, params.token1, params.fee, params.tickLower, params.tickUpper, params.amount0, params.amount1, params.deadline);

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams(params.token0, params.token1, params.fee, params.tickLower, params.tickUpper, swappedAmount0, swappedAmount1, 0, 0, address(this), params.deadline);

        (tokenId, liquidity, amount0, amount1) = nonfungiblePositionManager.mint(mintParams);

        _addToken(tokenId, params.recipient, false);

        // store balance in favor
        userBalances[params.recipient][params.token0] = swappedAmount0.sub(amount0);
        userBalances[params.recipient][params.token1] = swappedAmount1.sub(amount1);
    }

    /**
     * @notice Special method to decrease liquidity and collect decreased amount
     * Needs to do collect at the same time, otherwise the available amount would be autocompoundable
     */
    function decreaseLiquidityAndCollect(INonfungiblePositionManager.DecreaseLiquidityParams calldata params, address recipient) override external payable nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(ownerOf[params.tokenId] == msg.sender, "!owner");
        (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(params);
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams(params.tokenId, recipient, LiquidityAmounts.toUint128(amount0), LiquidityAmounts.toUint128(amount1));
        nonfungiblePositionManager.collect(collectParams);
    }

    /**
     * @notice Forwards collect call to NonfungiblePositionManager - can only be called by owner
     */
    function collect(INonfungiblePositionManager.CollectParams calldata params) override external payable nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(ownerOf[params.tokenId] == msg.sender, "!owner");
        return nonfungiblePositionManager.collect(params);
    }

    /**
     * @notice Main method to remove a NFT from the protocol
     */
    function withdrawToken(
        uint256 tokenId,
        address to,
        bytes memory data,
        bool withdrawBalances
    ) external override nonReentrant {
        require(to != address(this), "this");
        require(ownerOf[tokenId] == msg.sender, "!owner");

        _removeToken(msg.sender, tokenId);
        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId, data);
        emit TokenWithdrawn(msg.sender, to, tokenId);

        if (withdrawBalances) {
            (, , address token0, address token1, , , , , , , , ) = nonfungiblePositionManager.positions(tokenId);
            withdrawFullBalances(token0, token1, to);
        }
    }

    /**
     * @notice Withdraws token balance of a user
     */
    function withdrawBalance(address token, address to, uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        uint256 balance = userBalances[msg.sender][token];
        withdrawBalanceInternal(token, to, balance, amount);
    }

    function withdrawFullBalances(address token0, address token1, address to) internal {
        uint256 balance0 = userBalances[msg.sender][token0];
        if (balance0 > 0) {
            withdrawBalanceInternal(token0, to, balance0, balance0);
        }
        uint256 balance1 = userBalances[msg.sender][token1];
        if (balance1 > 0) {
            withdrawBalanceInternal(token1, to, balance1, balance1);
        }
    }

    function withdrawBalanceInternal(address token, address to, uint256 balance, uint256 amount) internal {
        require(amount <= balance, ">balance");
        userBalances[msg.sender][token] = userBalances[msg.sender][token].sub(amount);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit BalanceWithdrawn(msg.sender, token, to, amount);
    }
}