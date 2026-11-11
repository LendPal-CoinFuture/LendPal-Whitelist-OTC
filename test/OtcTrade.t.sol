// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessRegistry} from "../contracts/AccessRegistry.sol";
import {OtcTrade} from "../contracts/OtcTrade.sol";

contract TestUsdt is ERC20 {
    constructor() ERC20("Test USDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ReenteringUsdt is ERC20 {
    OtcTrade internal otc;
    uint256 internal tradeId;
    bool internal armed;

    constructor() ERC20("Reenter USDT", "rUSDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(OtcTrade otc_, uint256 tradeId_) external {
        otc = otc_;
        tradeId = tradeId_;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (armed) {
            armed = false;
            otc.settle(tradeId);
        }
        return super.transferFrom(from, to, value);
    }
}

contract OtcTradeTest is Test {
    AccessRegistry internal registry;
    OtcTrade internal otc;
    TestUsdt internal usdt;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant ORDER_ID = keccak256("order-1");

    function setUp() public {
        AccessRegistry impl = new AccessRegistry();
        registry = AccessRegistry(
            payable(
                address(
                    new ERC1967Proxy(address(impl), abi.encodeCall(AccessRegistry.initialize, (owner)))
                )
            )
        );

        vm.startPrank(owner);
        registry.addAdmin(admin, "");
        vm.stopPrank();

        vm.startPrank(admin);
        registry.addToWhitelist(buyer, "buyer");
        registry.addToWhitelist(seller, "seller");
        vm.stopPrank();

        OtcTrade otcImpl = new OtcTrade();
        otc = OtcTrade(
            address(
                new ERC1967Proxy(
                    address(otcImpl), abi.encodeCall(OtcTrade.initialize, (owner, address(registry)))
                )
            )
        );
        usdt = new TestUsdt();
        vm.prank(owner);
        otc.setUsdt(address(usdt));
        usdt.mint(buyer, 1_000_000e6);
    }

    function test_initializeSetsOwnerAndRegistry() public view {
        assertEq(otc.owner(), owner);
        assertEq(address(otc.registry()), address(registry));
    }

    function test_checkWhitelistedPair_bothOk() public view {
        (bool buyerOk, bool sellerOk) = otc.checkWhitelistedPair(buyer, seller);
        assertTrue(buyerOk);
        assertTrue(sellerOk);
    }

    function test_checkWhitelistedPair_ownerAndAdminCountAsListed() public view {
        (bool buyerOk, bool sellerOk) = otc.checkWhitelistedPair(buyer, owner);
        assertTrue(buyerOk);
        assertTrue(sellerOk);
        (buyerOk, sellerOk) = otc.checkWhitelistedPair(admin, seller);
        assertTrue(buyerOk);
        assertTrue(sellerOk);
    }

    function test_requireWhitelistedPair_okWithOwnerSeller() public view {
        otc.requireWhitelistedPair(buyer, owner);
    }

    function test_checkWhitelistedPair_buyerMissing() public view {
        (bool buyerOk, bool sellerOk) = otc.checkWhitelistedPair(stranger, seller);
        assertFalse(buyerOk);
        assertTrue(sellerOk);
    }

    function test_requireWhitelistedPair_ok() public view {
        otc.requireWhitelistedPair(buyer, seller);
    }

    function test_requireWhitelistedPair_revertsWhenBuyerNotListed() public {
        vm.expectRevert(OtcTrade.BuyerNotWhitelisted.selector);
        otc.requireWhitelistedPair(stranger, seller);
    }

    function test_requireWhitelistedPair_revertsWhenSellerNotListed() public {
        vm.expectRevert(OtcTrade.SellerNotWhitelisted.selector);
        otc.requireWhitelistedPair(buyer, stranger);
    }

    function test_requireWhitelistedPair_revertsWhenSameAddress() public {
        vm.expectRevert(OtcTrade.SameParticipant.selector);
        otc.requireWhitelistedPair(buyer, buyer);
    }

    function test_requireWhitelistedPair_revertsWhenZero() public {
        vm.expectRevert(OtcTrade.ZeroAddress.selector);
        otc.requireWhitelistedPair(address(0), seller);
    }

    function test_openTrade_andBothConfirm_completes() public {
        vm.prank(owner);
        (uint256 tradeId, bytes32 tradeHash) =
            otc.openTrade(buyer, seller, 100e6, 780_00, ORDER_ID, 0);

        assertEq(tradeId, 1);
        assertEq(otc.tradeCount(), 1);
        assertEq(
            tradeHash, otc.computeTradeHash(buyer, seller, 100e6, 780_00, ORDER_ID)
        );

        vm.prank(buyer);
        otc.confirmTrade(tradeId, tradeHash);

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            bool buyerConfirmed,
            bool sellerConfirmed,
            OtcTrade.TradeStatus status
        ) = otc.getTrade(tradeId);
        assertTrue(buyerConfirmed);
        assertFalse(sellerConfirmed);
        assertEq(uint8(status), uint8(OtcTrade.TradeStatus.Opened));

        vm.prank(seller);
        otc.confirmTrade(tradeId, tradeHash);

        (,,,,,,,,, sellerConfirmed, status) = otc.getTrade(tradeId);
        assertTrue(sellerConfirmed);
        assertEq(uint8(status), uint8(OtcTrade.TradeStatus.Opened));
        assertEq(otc.feeWallet(), owner);
    }

    function test_settlePullsDirectlyAndSplits99And1() public {
        uint256 amount = 100e6;
        vm.prank(owner);
        (uint256 tradeId, bytes32 tradeHash) = otc.openTrade(buyer, seller, amount, 780_00, ORDER_ID, 0);

        vm.prank(buyer);
        usdt.approve(address(otc), amount);
        vm.prank(buyer);
        otc.confirmTrade(tradeId, tradeHash);
        vm.prank(seller);
        otc.confirmTrade(tradeId, tradeHash);

        (uint256 fee, uint256 toSeller) = otc.quoteFee(amount);
        assertEq(fee, 1e6);
        assertEq(toSeller, 99e6);

        otc.settle(tradeId);
        assertEq(usdt.balanceOf(seller), 99e6);
        assertEq(usdt.balanceOf(owner), 1e6);
        assertEq(usdt.balanceOf(buyer), 1_000_000e6 - amount);
        assertEq(usdt.balanceOf(address(otc)), 0);
        (,,,,,,,,,, OtcTrade.TradeStatus status) = otc.getTrade(tradeId);
        assertEq(uint8(status), uint8(OtcTrade.TradeStatus.Completed));
    }

    function test_cancelBeforeSettleLeavesFundsWithBuyer() public {
        uint256 amount = 100e6;
        vm.prank(owner);
        (uint256 tradeId,) = otc.openTrade(buyer, seller, amount, 780_00, ORDER_ID, 0);
        vm.prank(buyer);
        usdt.approve(address(otc), amount);

        vm.prank(seller);
        otc.cancelTrade(tradeId);
        assertEq(usdt.balanceOf(buyer), 1_000_000e6);
        assertEq(usdt.balanceOf(address(otc)), 0);
        (,,,,,,,,,, OtcTrade.TradeStatus status) = otc.getTrade(tradeId);
        assertEq(uint8(status), uint8(OtcTrade.TradeStatus.Cancelled));
    }

    function test_depositAndRefundAreDisabled() public {
        vm.expectRevert(OtcTrade.CustodyDisabled.selector);
        otc.deposit(1);
        vm.expectRevert(OtcTrade.CustodyDisabled.selector);
        otc.refund(1);
    }

    function test_settleAfterPayerConfirmsOnce() public {
        uint256 amount = 50e6;
        vm.prank(owner);
        (uint256 tradeId, bytes32 tradeHash) = otc.openTrade(buyer, seller, amount, 1, ORDER_ID, 0);
        vm.prank(buyer);
        usdt.approve(address(otc), amount);
        vm.expectRevert(OtcTrade.NotFullyConfirmed.selector);
        otc.settle(tradeId);

        vm.prank(buyer);
        otc.confirmTrade(tradeId, tradeHash);
        otc.settle(tradeId);
        assertEq(usdt.balanceOf(seller), 49.5e6);
        assertEq(usdt.balanceOf(owner), 0.5e6);
        assertEq(usdt.balanceOf(address(otc)), 0);
    }

    function test_payOnceByPayerSplits99And1() public {
        uint256 amount = 50e6;
        vm.prank(buyer);
        usdt.approve(address(otc), amount);
        vm.prank(buyer);
        (uint256 tradeId,) = otc.pay(seller, amount, 390e6, "S-261110-7702074f");
        assertEq(usdt.balanceOf(seller), 49.5e6);
        assertEq(usdt.balanceOf(owner), 0.5e6);
        assertEq(usdt.balanceOf(buyer), 1_000_000e6 - amount);
        (,,,,,,,,,, OtcTrade.TradeStatus status) = otc.getTrade(tradeId);
        assertEq(uint8(status), uint8(OtcTrade.TradeStatus.Completed));
        (address paidBuyer, address paidSeller, uint256 paidUsdt,,,, uint64 openedAt,, bool buyerOk, bool sellerOk,) =
            otc.getTrade("S-261110-7702074f");
        assertEq(paidBuyer, buyer);
        assertEq(paidSeller, seller);
        assertEq(paidUsdt, amount);
        assertGt(openedAt, 0);
        assertTrue(buyerOk);
        assertFalse(sellerOk);
    }

    function test_payRejectsBadOrRepeatedOrderId() public {
        uint256 amount = 50e6;
        vm.startPrank(buyer);
        usdt.approve(address(otc), amount * 2);
        vm.expectRevert(OtcTrade.InvalidOrderId.selector);
        otc.pay(seller, amount, 390e6, "order-1");
        otc.pay(seller, amount, 390e6, "B-261110-7702074f");
        vm.expectRevert(OtcTrade.OrderAlreadyUsed.selector);
        otc.pay(seller, amount, 390e6, "B-261110-7702074f");
        vm.stopPrank();
        assertEq(usdt.balanceOf(buyer), 1_000_000e6 - amount);
    }

    function test_linkOrderReadsPreviousTradeWithoutMovingTokens() public {
        uint256 amount = 50e6;
        vm.prank(buyer);
        usdt.approve(address(otc), amount);
        vm.prank(buyer);
        otc.pay(seller, amount, 389e2, "S-261110-7702074f");
        uint256 sellerAfter = usdt.balanceOf(seller);

        OtcTrade next = OtcTrade(
            address(
                new ERC1967Proxy(
                    address(new OtcTrade()), abi.encodeCall(OtcTrade.initialize, (owner, address(registry)))
                )
            )
        );
        vm.startPrank(owner);
        next.setUsdt(address(usdt));
        next.setPreviousBook(address(otc));
        next.linkOrder("S-261110-7702074f", 1);
        vm.stopPrank();

        (address linkedBuyer, address linkedSeller, uint256 linkedUsdt,,,,,,,,) =
            next.getTrade("S-261110-7702074f");
        assertEq(linkedBuyer, buyer);
        assertEq(linkedSeller, seller);
        assertEq(linkedUsdt, amount);
        assertEq(usdt.balanceOf(seller), sellerAfter);
        assertEq(usdt.balanceOf(address(next)), 0);

        vm.prank(buyer);
        usdt.approve(address(next), amount);
        vm.prank(buyer);
        vm.expectRevert(OtcTrade.OrderAlreadyUsed.selector);
        next.pay(seller, amount, 389e2, "S-261110-7702074f");
    }

    function test_openTrade_revertsForNonOwner() public {
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, buyer)
        );
        otc.openTrade(buyer, seller, 1, 1, ORDER_ID, 0);
    }

    function test_openTrade_revertsWhenNotWhitelisted() public {
        vm.prank(owner);
        vm.expectRevert(OtcTrade.BuyerNotWhitelisted.selector);
        otc.openTrade(stranger, seller, 1, 1, ORDER_ID, 0);
    }

    function test_confirmTrade_revertsOnHashMismatch() public {
        vm.prank(owner);
        (uint256 tradeId,) = otc.openTrade(buyer, seller, 1, 1, ORDER_ID, 0);

        vm.prank(buyer);
        vm.expectRevert(OtcTrade.HashMismatch.selector);
        otc.confirmTrade(tradeId, bytes32(uint256(1)));
    }

    function test_confirmTrade_revertsForStranger() public {
        vm.prank(owner);
        (uint256 tradeId, bytes32 tradeHash) = otc.openTrade(buyer, seller, 1, 1, ORDER_ID, 0);

        vm.prank(stranger);
        vm.expectRevert(OtcTrade.NotTradeParty.selector);
        otc.confirmTrade(tradeId, tradeHash);
    }

    function test_confirmTrade_revertsWhenAlreadyConfirmed() public {
        vm.prank(owner);
        (uint256 tradeId, bytes32 tradeHash) = otc.openTrade(buyer, seller, 1, 1, ORDER_ID, 0);

        vm.prank(buyer);
        otc.confirmTrade(tradeId, tradeHash);

        vm.prank(buyer);
        vm.expectRevert(OtcTrade.AlreadyConfirmed.selector);
        otc.confirmTrade(tradeId, tradeHash);
    }

    function test_cancelTrade_byParty() public {
        vm.prank(owner);
        (uint256 tradeId,) = otc.openTrade(buyer, seller, 1, 1, ORDER_ID, 0);

        vm.prank(seller);
        otc.cancelTrade(tradeId);

        (,,,,,,,,,, OtcTrade.TradeStatus status) = otc.getTrade(tradeId);
        assertEq(uint8(status), uint8(OtcTrade.TradeStatus.Cancelled));
    }

    function test_cancelTrade_afterExpiry_byAnyone() public {
        uint64 expiry = uint64(block.timestamp + 100);
        vm.prank(owner);
        (uint256 tradeId,) = otc.openTrade(buyer, seller, 1, 1, ORDER_ID, expiry);

        vm.warp(expiry + 1);
        vm.prank(stranger);
        otc.cancelTrade(tradeId);

        (,,,,,,,,,, OtcTrade.TradeStatus status) = otc.getTrade(tradeId);
        assertEq(uint8(status), uint8(OtcTrade.TradeStatus.Cancelled));
    }

    function test_confirmTrade_revertsWhenExpired() public {
        uint64 expiry = uint64(block.timestamp + 50);
        vm.prank(owner);
        (uint256 tradeId, bytes32 tradeHash) =
            otc.openTrade(buyer, seller, 1, 1, ORDER_ID, expiry);

        vm.warp(expiry + 1);
        vm.prank(buyer);
        vm.expectRevert(OtcTrade.TradeExpired.selector);
        otc.confirmTrade(tradeId, tradeHash);
    }

    function test_upgradeIsDisabled() public {
        OtcTrade next = new OtcTrade();
        vm.prank(owner);
        vm.expectRevert(OtcTrade.UpgradeDisabled.selector);
        otc.upgradeToAndCall(address(next), "");
    }

    function test_feeDefaultsTo1AndRejectsAbove5() public {
        assertEq(otc.currentFeePercent(), 1);
        (uint256 fee, uint256 toSeller) = otc.quoteFee(100e6);
        assertEq(fee, 1e6);
        assertEq(toSeller, 99e6);

        vm.prank(owner);
        otc.setFeePercent(5);
        (fee, toSeller) = otc.quoteFee(100e6);
        assertEq(fee, 5e6);
        assertEq(toSeller, 95e6);

        vm.prank(owner);
        vm.expectRevert(OtcTrade.FeePercentOutOfRange.selector);
        otc.setFeePercent(6);

        vm.prank(owner);
        vm.expectRevert(OtcTrade.FeePercentOutOfRange.selector);
        otc.setFeePercent(0);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger)
        );
        otc.setFeePercent(2);
    }

    function test_openTradeLocksFeeBeforeLaterChange() public {
        uint256 amount = 100e6;
        vm.prank(owner);
        otc.setFeePercent(5);
        vm.prank(owner);
        (uint256 tradeId, bytes32 tradeHash) = otc.openTrade(buyer, seller, amount, 780_00, ORDER_ID, 0);
        vm.prank(owner);
        otc.setFeePercent(1);

        assertEq(otc.tradeFeePercent(tradeId), 5);
        (uint256 fee, uint256 toSeller) = otc.quoteTradeFee(tradeId);
        assertEq(fee, 5e6);
        assertEq(toSeller, 95e6);

        vm.prank(buyer);
        usdt.approve(address(otc), amount);
        vm.prank(buyer);
        otc.confirmTrade(tradeId, tradeHash);
        vm.prank(seller);
        otc.confirmTrade(tradeId, tradeHash);
        otc.settle(tradeId);
        assertEq(usdt.balanceOf(address(otc)), 0);

        assertEq(usdt.balanceOf(seller), 95e6);
        assertEq(usdt.balanceOf(owner), 5e6);
    }

    function test_feeRecipientCannotBeTheContract() public {
        vm.prank(owner);
        vm.expectRevert(OtcTrade.FeeRecipientIsContract.selector);
        otc.setFeeRecipient(address(otc));
        assertEq(otc.feeWallet(), owner);

        address treasury = makeAddr("treasury");
        vm.prank(owner);
        otc.setFeeRecipient(treasury);
        assertEq(otc.feeWallet(), treasury);

        vm.prank(owner);
        otc.setFeeRecipient(address(0));
        assertEq(otc.feeWallet(), owner);
    }

    function test_settleRevertsOnReentry() public {
        ReenteringUsdt bad = new ReenteringUsdt();
        AccessRegistry registryImpl = new AccessRegistry();
        AccessRegistry localRegistry = AccessRegistry(
            payable(address(new ERC1967Proxy(address(registryImpl), abi.encodeCall(AccessRegistry.initialize, (owner)))))
        );
        vm.prank(owner);
        localRegistry.addAdmin(admin, "");
        vm.startPrank(admin);
        localRegistry.addToWhitelist(buyer, "buyer");
        localRegistry.addToWhitelist(seller, "seller");
        vm.stopPrank();

        OtcTrade local = OtcTrade(
            address(
                new ERC1967Proxy(
                    address(new OtcTrade()), abi.encodeCall(OtcTrade.initialize, (owner, address(localRegistry)))
                )
            )
        );
        vm.prank(owner);
        local.setUsdt(address(bad));
        bad.mint(buyer, 100e6);

        vm.prank(owner);
        (uint256 tradeId, bytes32 tradeHash) = local.openTrade(buyer, seller, 100e6, 780_00, ORDER_ID, 0);
        vm.prank(buyer);
        bad.approve(address(local), 100e6);
        vm.prank(buyer);
        local.confirmTrade(tradeId, tradeHash);
        vm.prank(seller);
        local.confirmTrade(tradeId, tradeHash);
        bad.arm(local, tradeId);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        local.settle(tradeId);
        assertEq(bad.balanceOf(buyer), 100e6);
        assertEq(bad.balanceOf(address(local)), 0);
        (,,,,,,,,,, OtcTrade.TradeStatus status) = local.getTrade(tradeId);
        assertEq(uint8(status), uint8(OtcTrade.TradeStatus.Opened));
    }
}
