// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract UniswapCloneWithRewards is ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Pair {
        address token0;
        address token1;
        uint256 reserve0;
        uint256 reserve1;
        uint256 totalLiquidity;
    }

    struct UserInfo {
        uint256 liquidity;
        uint256 rewardDebt;
    }

    mapping(bytes32 => Pair) public pairs;
    mapping(address => bool) public registeredTokens;
    mapping(bytes32 => mapping(address => UserInfo)) public userInfo;

    IERC20 public rewardToken;
    uint256 public rewardPerBlock;
    uint256 public lastUpdateBlock;
    uint256 public accRewardPerShare;

    LoyaltyProgram public loyaltyProgram;

    event TokenRegistered(address indexed token);
    event PairCreated(address indexed token0, address indexed token1);
    event Swap(address indexed sender, uint256 amountIn, uint256 amountOut, address indexed tokenIn, address indexed tokenOut);
    event LiquidityAdded(address indexed user, address indexed token0, address indexed token1, uint256 amount0, uint256 amount1);
    event RewardPaid(address indexed user, uint256 reward);

    constructor(IERC20 _rewardToken, uint256 _rewardPerBlock) {
        rewardToken = _rewardToken;
        rewardPerBlock = _rewardPerBlock;
        lastUpdateBlock = block.number;
        loyaltyProgram = new LoyaltyProgram("LoyaltyNFT", "LNFT");
    }

    function registerToken(address token) external {
        require(!registeredTokens[token], "Token already registered");
        require(IERC20(token).totalSupply() > 0, "Invalid token");

        registeredTokens[token] = true;
        emit TokenRegistered(token);
    }

    function createPair(address tokenA, address tokenB) external nonReentrant {
        require(tokenA != tokenB, "UniswapClone: IDENTICAL_ADDRESSES");
        require(registeredTokens[tokenA] && registeredTokens[tokenB], "UniswapClone: TOKEN_NOT_REGISTERED");

        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 pairHash = keccak256(abi.encodePacked(token0, token1));
        require(pairs[pairHash].token0 == address(0), "UniswapClone: PAIR_EXISTS");

        pairs[pairHash] = Pair({
            token0: token0,
            token1: token1,
            reserve0: 0,
            reserve1: 0,
            totalLiquidity: 0
        });

        emit PairCreated(token0, token1);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired
    ) external nonReentrant returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 pairHash = keccak256(abi.encodePacked(token0, token1));
        require(pairs[pairHash].token0 != address(0), "UniswapClone: PAIR_NOT_FOUND");

        Pair storage pair = pairs[pairHash];

        updatePool(pairHash);

        if (pair.reserve0 == 0 && pair.reserve1 == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
            liquidity = Math.sqrt(amountA.mul(amountB));
        } else {
            uint256 amountBOptimal = quote(amountADesired, pair.reserve0, pair.reserve1);
            if (amountBOptimal <= amountBDesired) {
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = quote(amountBDesired, pair.reserve1, pair.reserve0);
                assert(amountAOptimal <= amountADesired);
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
            liquidity = Math.min(amountA.mul(pair.totalLiquidity) / pair.reserve0, amountB.mul(pair.totalLiquidity) / pair.reserve1);
        }

        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountB);

        pair.reserve0 = pair.reserve0.add(amountA);
        pair.reserve1 = pair.reserve1.add(amountB);
        pair.totalLiquidity = pair.totalLiquidity.add(liquidity);

        UserInfo storage user = userInfo[pairHash][msg.sender];
        if (user.liquidity > 0) {
            uint256 pending = user.liquidity.mul(accRewardPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                rewardToken.safeTransfer(msg.sender, pending);
                emit RewardPaid(msg.sender, pending);
            }
        }
        user.liquidity = user.liquidity.add(liquidity);
        user.rewardDebt = user.liquidity.mul(accRewardPerShare).div(1e12);

        emit LiquidityAdded(msg.sender, tokenA, tokenB, amountA, amountB);

        return (amountA, amountB, liquidity);
    }

    function swap(
        uint256 amountIn,
        address tokenIn,
        address tokenOut
    ) external nonReentrant returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapClone: INSUFFICIENT_INPUT_AMOUNT");
        require(tokenIn != tokenOut, "UniswapClone: IDENTICAL_ADDRESSES");

        (address token0, address token1) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        bytes32 pairHash = keccak256(abi.encodePacked(token0, token1));
        require(pairs[pairHash].token0 != address(0), "UniswapClone: PAIR_NOT_FOUND");

        Pair storage pair = pairs[pairHash];

        uint256 reserveIn = tokenIn == token0 ? pair.reserve0 : pair.reserve1;
        uint256 reserveOut = tokenIn == token0 ? pair.reserve1 : pair.reserve0;

        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        require(amountOut > 0, "UniswapClone: INSUFFICIENT_OUTPUT_AMOUNT");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        uint256 balanceIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 balanceOut = IERC20(tokenOut).balanceOf(address(this));

        if (tokenIn == token0) {
            pair.reserve0 = balanceIn;
            pair.reserve1 = balanceOut;
        } else {
            pair.reserve0 = balanceOut;
            pair.reserve1 = balanceIn;
        }

        emit Swap(msg.sender, amountIn, amountOut, tokenIn, tokenOut);

        return amountOut;
    }

    function updatePool(bytes32 pairHash) public {
        Pair storage pair = pairs[pairHash];
        if (block.number <= lastUpdateBlock) {
            return;
        }
        if (pair.totalLiquidity == 0) {
            lastUpdateBlock = block.number;
            return;
        }
        uint256 multiplier = block.number.sub(lastUpdateBlock);
        uint256 reward = multiplier.mul(rewardPerBlock);
        accRewardPerShare = accRewardPerShare.add(reward.mul(1e12).div(pair.totalLiquidity));
        lastUpdateBlock = block.number;
    }

    function pendingReward(bytes32 pairHash, address _user) external view returns (uint256) {
        Pair storage pair = pairs[pairHash];
        UserInfo storage user = userInfo[pairHash][_user];
        uint256 _accRewardPerShare = accRewardPerShare;
        if (block.number > lastUpdateBlock && pair.totalLiquidity != 0) {
            uint256 multiplier = block.number.sub(lastUpdateBlock);
            uint256 reward = multiplier.mul(rewardPerBlock);
            _accRewardPerShare = _accRewardPerShare.add(reward.mul(1e12).div(pair.totalLiquidity));
        }
        return user.liquidity.mul(_accRewardPerShare).div(1e12).sub(user.rewardDebt);
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        require(amountA > 0, "UniswapClone: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "UniswapClone: INSUFFICIENT_LIQUIDITY");
        amountB = amountA.mul(reserveB) / reserveA;
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapClone: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapClone: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn.mul(997);
        uint256 numerator = amountInWithFee.mul(reserveOut);
        uint256 denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    function mintLoyaltyToken() external {
        loyaltyProgram.mint(msg.sender);
    }

    function burnLoyaltyToken(uint256 tokenId) external {
        loyaltyProgram.burn(msg.sender, tokenId);
    }

    function setLoyaltyTokenTransferable(bool transferable) external onlyOwner {
        loyaltyProgram.setTransferable(transferable);
    }
}

contract LoyaltyProgram is ERC721, Ownable {
    uint256 private _tokenIdCounter;
    bool public transferable;

    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {
        transferable = false;
    }

    function mint(address to) external {
        _tokenIdCounter++;
        _safeMint(to, _tokenIdCounter);
    }

    function burn(address from, uint256 tokenId) external {
        require(ownerOf(tokenId) == from, "LoyaltyProgram: Not token owner");
        _burn(tokenId);
    }

    function setTransferable(bool _transferable) external onlyOwner {
        transferable = _transferable;
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize) internal override {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
        require(transferable || from == address(0) || to == address(0), "LoyaltyProgram: Transfers are currently disabled");
    }
}