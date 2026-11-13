// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessRegistry} from "../contracts/AccessRegistry.sol";
import {PledgeLoan} from "../contracts/PledgeLoan.sol";

contract PledgeUsdt is ERC20 {
    constructor() ERC20("Test USDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PledgeLoanTest is Test {
    AccessRegistry internal registry;
    PledgeLoan internal book;
    PledgeUsdt internal usdt;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal pledgor = makeAddr("pledgor");
    address internal counterparty = makeAddr("counterparty");

    function setUp() public {
        AccessRegistry impl = new AccessRegistry();
        registry = AccessRegistry(
            payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(AccessRegistry.initialize, (owner)))))
        );
        vm.prank(owner);
        registry.addAdmin(admin, "");
        vm.startPrank(admin);
        registry.addToWhitelist(pledgor, "pledgor");
        registry.addToWhitelist(counterparty, "counterparty");
        vm.stopPrank();

        usdt = new PledgeUsdt();
        book = new PledgeLoan(address(registry), address(usdt));
        usdt.mint(pledgor, 1_000_000e6);
        vm.prank(pledgor);
        usdt.approve(address(book), type(uint256).max);
    }

    function test_deliverSendsAllUsdtToCounterparty() public {
        vm.prank(pledgor);
        uint256 id = book.deliver(counterparty, 100e6, 14, "PL-261112-1e23caa0");
        assertEq(usdt.balanceOf(counterparty), 100e6);
        assertEq(usdt.balanceOf(address(book)), 0);
        assertEq(usdt.balanceOf(pledgor), 1_000_000e6 - 100e6);
        PledgeLoan.Loan memory loan = book.getLoan(id);
        assertEq(loan.pledgor, pledgor);
        assertEq(loan.counterparty, counterparty);
        assertEq(loan.principal, 100e6);
        assertEq(loan.termDays, 14);
        assertFalse(loan.repaid);
    }

    function test_deliverRejectsSecondUseAndStrangers() public {
        vm.prank(pledgor);
        book.deliver(counterparty, 100e6, 7, "PL-1");
        vm.prank(pledgor);
        vm.expectRevert(PledgeLoan.OrderUsed.selector);
        book.deliver(counterparty, 100e6, 7, "PL-1");

        address stranger = makeAddr("stranger");
        usdt.mint(stranger, 10e6);
        vm.startPrank(stranger);
        usdt.approve(address(book), type(uint256).max);
        vm.expectRevert(PledgeLoan.NotWhitelisted.selector);
        book.deliver(counterparty, 10e6, 7, "PL-2");
        vm.stopPrank();
    }

    function test_interestIsFreeForSevenDaysThenCapped() public view {
        assertEq(book.interestDue(100e6, 1_000, 14, 1_000 + 7 days), 0);
        assertEq(book.interestDue(100e6, 1_000, 14, 1_000 + 8 days), 100e6 * 10 / 10_000);
        assertEq(book.interestDue(100e6, 1_000, 7, 1_000 + 40 days), 0);
        assertEq(book.interestDue(100e6, 1_000, 14, 1_000 + 100 days), 100e6 * 7 * 10 / 10_000);
    }

    function test_repayReturnsPrincipal() public {
        vm.prank(pledgor);
        uint256 id = book.deliver(counterparty, 100e6, 14, "PL-3");
        vm.warp(block.timestamp + 8 days);
        vm.startPrank(counterparty);
        usdt.approve(address(book), type(uint256).max);
        book.repay(id);
        vm.stopPrank();
        assertEq(usdt.balanceOf(pledgor), 1_000_000e6);
        assertEq(usdt.balanceOf(counterparty), 0);
        assertTrue(book.getLoan(id).repaid);

        vm.prank(counterparty);
        vm.expectRevert(PledgeLoan.AlreadyRepaid.selector);
        book.repay(id);
    }

    function test_onlyCounterpartyRepays() public {
        vm.prank(pledgor);
        uint256 id = book.deliver(counterparty, 100e6, 14, "PL-4");
        vm.prank(pledgor);
        vm.expectRevert(PledgeLoan.NotCounterparty.selector);
        book.repay(id);
    }
}
