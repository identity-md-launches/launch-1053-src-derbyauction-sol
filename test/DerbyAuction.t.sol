// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DerbyAuction, ISwarmDerby} from "../src/DerbyAuction.sol";
import {SwarmDerby, IERC20} from "../src/SwarmDerby.sol";
import {DerbyOdds} from "../src/DerbyOdds.sol";

// Same ArbSys pattern as SwarmDerby.t.sol: the only mocked game dependency.
contract AuctionArbSys {
    uint256 public arbBlockNumber;
    mapping(uint256 => bytes32) public hashes;

    function setBlock(uint256 n) external {
        arbBlockNumber = n;
    }

    function setHash(uint256 n, bytes32 h) external {
        hashes[n] = h;
    }

    function arbBlockHash(uint256 n) external view returns (bytes32) {
        require(n < arbBlockNumber && n + 256 >= arbBlockNumber, "range");
        return hashes[n] != bytes32(0) ? hashes[n] : keccak256(abi.encode("blk", n));
    }
}

contract AuctionToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint8) public failure;
    bool public noReturn;
    uint8 public pullFailure;
    uint256 public shortfall;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;
    uint256 public callbacks;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address to, uint256 amount) external returns (bool) {
        allowance[msg.sender][to] = amount;
        return true;
    }

    function setFailure(address to, uint8 mode) external {
        failure[to] = mode;
    }

    function setNoReturn(bool value) external {
        noReturn = value;
    }

    function setPullFailure(uint8 value) external {
        pullFailure = value;
    }

    function setShortfall(uint256 value) external {
        shortfall = value;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function _respond(uint8 mode) internal pure {
        if (mode == 1) revert("blocked");
        if (mode == 2) {
            assembly ("memory-safe") {
                mstore(0, 0)
                return(0, 32)
            }
        }
        if (mode == 3) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 1)
            }
        }
        if (mode == 4) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
    }

    function _callback() internal {
        if (callbackTarget != address(0)) {
            ++callbacks;
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        }
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _respond(failure[to]);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        _callback();
        if (noReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _respond(pullFailure);
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - shortfall;
        _callback();
        if (noReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }
}

contract AuctionNeverCall {
    fallback() external {
        revert("constructor must not call dependencies");
    }
}

contract DerbyAuctionTest is Test {
    AuctionArbSys internal arb = AuctionArbSys(address(100));
    AuctionToken internal imd;
    SwarmDerby internal derby;
    DerbyAuction internal sale;
    address internal alice = makeAddr("bidder Alice");
    address internal bob = makeAddr("bidder Bob");
    address internal carol = makeAddr("bidder Carol");
    address internal studio = makeAddr("studio");
    address internal payer = makeAddr("bonus payer");
    uint256 internal constant DAY = 20_400;

    function setUp() public {
        // Use a vanilla local chain: recent Foundry versions intercept ArbSys on 4663,
        // bypassing the etched mock's arbBlockNumber even without an RPC fork.
        vm.chainId(31337);
        vm.warp(_start(DAY));
        vm.etch(address(100), address(new AuctionArbSys()).code);
        arb.setBlock(1_000);
        imd = new AuctionToken();
        derby = new SwarmDerby(address(this), IERC20(address(imd)), 0.15 ether, 0.5 ether);
        sale = new DerbyAuction(address(this), IERC20(address(imd)), ISwarmDerby(address(derby)), studio, 0);
    }

    function _start(uint256 day) internal pure returns (uint256) {
        return (day - 2) * 1 days + 18 hours;
    }

    function _end(uint256 day) internal pure returns (uint256) {
        return (day - 1) * 1 days + 18 hours;
    }

    function _grace(uint256 day) internal pure returns (uint256) {
        return (day + 1) * 1 days + 7 days;
    }

    function _answers() internal pure returns (DerbyAuction.Answers memory) {
        return DerbyAuction.Answers("Comet critter", 3, 5, 5, "Starlight Derby", "Hello team!");
    }

    function _state(uint256 day) internal view returns (DerbyAuction.Auction memory a) {
        (a.leader, a.amount, a.end, a.settled, a.vetoed, a.paid, a.bonus) = sale.auction(day);
    }

    function _fund(address who, uint256 amount) internal {
        imd.mint(who, amount);
        vm.prank(who);
        imd.approve(address(sale), amount);
    }

    function _bid(uint256 day, address who, uint256 amount) internal {
        _fund(who, amount);
        vm.prank(who);
        sale.bid(day, amount, _answers());
    }

    function _settled(uint256 amount) internal {
        _bid(DAY, alice, amount);
        vm.warp(_state(DAY).end);
        sale.settle(DAY);
    }

    function _buy(address who, uint8 league) internal {
        imd.mint(who, 0.15 ether);
        vm.startPrank(who);
        imd.approve(address(derby), 0.15 ether);
        derby.buyTurns(league, 1);
        vm.stopPrank();
    }

    /// Play an actual commit and reveal. Control only ArbSys's future hash, as the existing tests do.
    function _homer(uint8 league, address who, uint8 wantedTier) internal returns (uint16 feet) {
        _buy(who, league);
        uint256 id = derby.nextSwingId();
        bytes32 salt = keccak256(abi.encode("auction integration", id, who));
        bytes32 commitment = derby.commitFor(salt, who);
        uint256 target = arb.arbBlockNumber() + derby.REVEAL_DELAY();
        vm.prank(who);
        assertEq(derby.swing(league, 100, 100, commitment), id);
        bytes32 hash;
        for (uint256 i;; ++i) {
            hash = keccak256(abi.encode("future block", id, i));
            (uint8 tier, uint16 distance) = DerbyOdds.roll(derby.swingSeed(salt, hash), id, 100, 100);
            if (tier == wantedTier) {
                feet = distance;
                break;
            }
        }
        arb.setHash(target, hash);
        arb.setBlock(target + 1);
        (uint8 actualTier, uint16 actualFeet) = derby.finalize(id, salt);
        assertEq(actualTier, wantedTier);
        assertEq(actualFeet, feet);
    }

    function _player(uint256 i) internal pure returns (address) {
        return address(uint160(0x10000 + i));
    }

    function _board(uint256 count) internal {
        for (uint256 i; i < count; ++i) {
            _homer(0, _player(i), DerbyOdds.HOMER);
        }
    }

    function _close(uint256 day) internal {
        vm.warp((day + 1) * 1 days);
        arb.setBlock(arb.arbBlockNumber() + 1_000);
        assertTrue(derby.dayClosed(0, day));
    }

    function _pay(uint256 day) internal {
        vm.prank(payer);
        sale.payBonus(day);
    }

    function test_constructorStoresArgumentsWithoutAnyDependencyCalls() public {
        address absentToken = makeAddr("not yet deployed token");
        address absentDerby = makeAddr("not yet deployed derby");
        vm.expectCall(absentToken, bytes(""), uint64(0));
        vm.expectCall(absentDerby, bytes(""), uint64(0));
        DerbyAuction fresh = new DerbyAuction(bob, IERC20(absentToken), ISwarmDerby(absentDerby), carol, 1 ether);
        assertEq(fresh.owner(), bob);
        assertEq(address(fresh.imd()), absentToken);
        assertEq(address(fresh.derby()), absentDerby);
        assertEq(fresh.studio(), carol);
        assertEq(fresh.buildFee(), 1 ether);
        address trap = address(new AuctionNeverCall());
        vm.expectCall(trap, bytes(""), uint64(0));
        new DerbyAuction(bob, IERC20(trap), ISwarmDerby(trap), carol, 0);
        vm.expectRevert(DerbyAuction.NotAContract.selector);
        fresh.bid(DAY, 2 ether, _answers());
    }

    function test_constructorRejectsZeroAddressesAndExcessFee() public {
        vm.expectRevert(DerbyAuction.ZeroAddress.selector);
        new DerbyAuction(address(0), IERC20(address(imd)), ISwarmDerby(address(derby)), studio, 0);
        vm.expectRevert(DerbyAuction.ZeroAddress.selector);
        new DerbyAuction(alice, IERC20(address(0)), ISwarmDerby(address(derby)), studio, 0);
        vm.expectRevert(DerbyAuction.ZeroAddress.selector);
        new DerbyAuction(alice, IERC20(address(imd)), ISwarmDerby(address(0)), studio, 0);
        vm.expectRevert(DerbyAuction.ZeroAddress.selector);
        new DerbyAuction(alice, IERC20(address(imd)), ISwarmDerby(address(derby)), address(0), 0);
        vm.expectRevert(DerbyAuction.BadFee.selector);
        new DerbyAuction(alice, IERC20(address(imd)), ISwarmDerby(address(derby)), studio, 1 ether + 1);
    }

    function test_openDayAndBidTimeBoundaries() public {
        vm.warp(_start(DAY) - 1);
        assertEq(sale.openDay(), DAY - 1);
        vm.expectRevert(DerbyAuction.BidClosed.selector);
        sale.bid(DAY, 2 ether, _answers());
        vm.warp(_start(DAY));
        assertEq(sale.openDay(), DAY);
        assertEq(_state(DAY).end, _end(DAY));
        _bid(DAY, alice, 2 ether);
        vm.warp(_end(DAY));
        assertEq(sale.openDay(), DAY + 1);
        vm.expectRevert(DerbyAuction.BidClosed.selector);
        sale.bid(DAY, 3 ether, _answers());
        vm.warp(_end(DAY) + 1);
        vm.expectRevert(DerbyAuction.BidClosed.selector);
        sale.bid(DAY, 3 ether, _answers());
        vm.warp(0);
        assertEq(sale.openDay(), 1);
        vm.expectRevert(DerbyAuction.BadDay.selector);
        sale.bid(0, 2 ether, _answers());
        vm.expectRevert(DerbyAuction.BadDay.selector);
        sale.settle(1);
    }

    function test_bidMinimumAndIncrementRoundUp() public {
        assertEq(sale.minNextBid(DAY), 2 ether);
        vm.expectRevert(DerbyAuction.BidTooLow.selector);
        sale.bid(DAY, 0, _answers());
        vm.expectRevert(DerbyAuction.BidTooLow.selector);
        sale.bid(DAY, 2 ether - 1, _answers());
        _bid(DAY, alice, 2 ether + 1);
        assertEq(sale.minNextBid(DAY), 2.1 ether + 2);
        vm.expectRevert(DerbyAuction.BidTooLow.selector);
        sale.bid(DAY, 2.1 ether + 1, _answers());
        _bid(DAY, bob, 2.1 ether + 2);
        assertEq(_state(DAY).leader, bob);
    }

    function _badAnswers(DerbyAuction.Answers memory a) internal {
        vm.expectRevert(DerbyAuction.BadAnswers.selector);
        sale.bid(DAY, 2 ether, a);
    }

    function test_answerLengthsAndEnums() public {
        DerbyAuction.Answers memory a = _answers();
        a.creature = "";
        _badAnswers(a);
        a.creature = "1234567890123456789012345";
        _badAnswers(a);
        a = _answers();
        a.title = "";
        _badAnswers(a);
        a.title = "1234567890123456789012345";
        _badAnswers(a);
        a = _answers();
        a.shoutout = "12345678901234567890123456789012345";
        _badAnswers(a);
        a = _answers();
        a.vibe = 4;
        _badAnswers(a);
        a = _answers();
        a.vibe = 255;
        _badAnswers(a);
        a = _answers();
        a.stadium = 6;
        _badAnswers(a);
        a = _answers();
        a.weather = 6;
        _badAnswers(a);
    }

    function test_everyForbiddenByteRejectedInEveryString() public {
        for (uint256 i; i < 256; ++i) {
            if (i >= 0x20 && i <= 0x7e && i != 0x3c && i != 0x3e && i != 0x22 && i != 0x5c) continue;
            string memory bad = string(abi.encodePacked(bytes1(uint8(i))));
            DerbyAuction.Answers memory a = _answers();
            a.creature = bad;
            _badAnswers(a);
            a = _answers();
            a.title = bad;
            _badAnswers(a);
            a = _answers();
            a.shoutout = bad;
            _badAnswers(a);
        }
    }

    function test_answerBoundaryValuesStoredAndBidEmitted() public {
        DerbyAuction.Answers memory a = DerbyAuction.Answers(
            "123456789012345678901234", 3, 5, 5, "123456789012345678901234", "12345678901234567890123456789012"
        );
        _fund(alice, 2 ether);
        vm.expectEmit(true, true, false, true, address(sale));
        emit DerbyAuction.Bid(DAY, alice, 2 ether, _end(DAY), a.creature, 3, 5, 5, a.title, a.shoutout);
        vm.prank(alice);
        sale.bid(DAY, 2 ether, a);
        assertEq(abi.encode(sale.answers(DAY)), abi.encode(a));
        a = DerbyAuction.Answers(" ~!#$%&'()*+,-./:;=?@[]^", 0, 0, 0, "a", "");
        _fund(bob, 3 ether);
        vm.prank(bob);
        sale.bid(DAY, 3 ether, a);
        assertEq(abi.encode(sale.answers(DAY)), abi.encode(a));
    }

    function test_outbidAndSelfRaiseRefundPreviousBid() public {
        _bid(DAY, alice, 2 ether);
        _bid(DAY, bob, 3 ether);
        assertEq(imd.balanceOf(alice), 2 ether);
        assertEq(imd.balanceOf(address(sale)), 3 ether);
        _bid(DAY, bob, 4 ether);
        assertEq(imd.balanceOf(bob), 3 ether);
        assertEq(imd.balanceOf(address(sale)), 4 ether);
        assertEq(sale.refunds(alice), 0);
        assertEq(sale.refunds(bob), 0);
        assertEq(_state(DAY).amount, 4 ether);
    }

    function test_failedRefundAccumulatesAndWithdrawsOnlyOnce() public {
        _bid(DAY, alice, 2 ether);
        imd.setFailure(alice, 1);
        _fund(bob, 3 ether);
        vm.expectEmit(true, false, false, true, address(sale));
        emit DerbyAuction.RefundCredited(alice, 2 ether);
        vm.prank(bob);
        sale.bid(DAY, 3 ether, _answers());
        _bid(DAY, alice, 4 ether);
        _bid(DAY, alice, 5 ether);
        assertEq(sale.refunds(alice), 6 ether);
        assertEq(imd.balanceOf(address(sale)), 11 ether);
        vm.prank(alice);
        vm.expectRevert(DerbyAuction.TransferFailed.selector);
        sale.withdrawRefund();
        assertEq(sale.refunds(alice), 6 ether);
        vm.prank(bob);
        vm.expectRevert(DerbyAuction.NoRefund.selector);
        sale.withdrawRefund();
        imd.setFailure(alice, 0);
        vm.prank(alice);
        sale.withdrawRefund();
        assertEq(imd.balanceOf(alice), 6 ether);
        assertEq(sale.refunds(alice), 0);
        assertEq(imd.balanceOf(address(sale)), 5 ether);
        vm.prank(alice);
        vm.expectRevert(DerbyAuction.NoRefund.selector);
        sale.withdrawRefund();
    }

    function test_falseAndMalformedRefundsDoNotBlockBids() public {
        _bid(DAY, alice, 2 ether);
        for (uint8 mode = 2; mode <= 4; ++mode) {
            imd.setFailure(alice, mode);
            uint256 previous = _state(DAY).amount;
            _bid(DAY, alice, previous + 1 ether);
        }
        assertEq(sale.refunds(alice), 9 ether);
        assertEq(imd.balanceOf(address(sale)), 14 ether);
    }

    function test_fullNewBidMustBeFundedBeforeSelfRefund() public {
        _bid(DAY, alice, 2 ether);
        _fund(alice, 0.1 ether);
        vm.prank(alice);
        vm.expectRevert(DerbyAuction.TransferFailed.selector);
        sale.bid(DAY, 2.1 ether, _answers());
        assertEq(_state(DAY).amount, 2 ether);
        assertEq(imd.balanceOf(address(sale)), 2 ether);
    }

    function test_antiSnipeExtendsRepeatedlyAndKeepsOtherDaysIndependent() public {
        vm.warp(_end(DAY) - 300);
        _bid(DAY, alice, 2 ether);
        assertEq(_state(DAY).end, _end(DAY));
        vm.warp(_end(DAY) - 299);
        _bid(DAY, bob, 3 ether);
        assertEq(_state(DAY).end, _end(DAY) + 1);
        for (uint256 i; i < 5; ++i) {
            uint256 oldEnd = _state(DAY).end;
            vm.warp(oldEnd - 1);
            _bid(DAY, alice, 4 ether + i * 1 ether);
            assertEq(_state(DAY).end, oldEnd + 299);
        }
        assertEq(_state(DAY + 1).end, _end(DAY + 1));
        vm.expectRevert(DerbyAuction.TooEarly.selector);
        sale.settle(DAY);
        vm.warp(_state(DAY).end);
        vm.expectRevert(DerbyAuction.BidClosed.selector);
        sale.bid(DAY, 20 ether, _answers());
        sale.settle(DAY);
    }

    /// Two wallets alternate minimum bids every 299 seconds. Extensions stop at 19:00 UTC,
    /// so the auction settles before the theme day and the owner can still veto it.
    function test_antiSnipeStopsAtOneHourSoVetoStaysOpen() public {
        uint256 latest = _end(DAY) + sale.MAX_EXTENSION();
        vm.warp(_end(DAY) - 1);
        _bid(DAY, alice, 2 ether);
        address next = bob;
        while (_state(DAY).end < latest) {
            vm.warp(_state(DAY).end - 1);
            _bid(DAY, next, sale.minNextBid(DAY));
            next = next == bob ? alice : bob;
        }
        assertEq(_state(DAY).end, latest);
        vm.warp(latest - 1);
        _bid(DAY, next, sale.minNextBid(DAY));
        assertEq(_state(DAY).end, latest);
        vm.warp(latest);
        vm.expectRevert(DerbyAuction.BidClosed.selector);
        sale.bid(DAY, 100 ether, _answers());
        sale.settle(DAY);
        assertLt(block.timestamp, DAY * 1 days);
        sale.veto(DAY);
        assertTrue(_state(DAY).vetoed);
    }

    function test_settleZeroFeeExactlyAndOnlyOnce() public {
        vm.expectRevert(DerbyAuction.TooEarly.selector);
        sale.settle(DAY);
        _bid(DAY, alice, 2 ether);
        vm.warp(_end(DAY));
        vm.expectEmit(true, true, false, true, address(sale));
        emit DerbyAuction.Settled(DAY, alice, 2 ether, 0, 2 ether);
        vm.prank(bob);
        sale.settle(DAY);
        assertTrue(_state(DAY).settled);
        assertEq(_state(DAY).bonus, 2 ether);
        assertEq(imd.balanceOf(studio), 0);
        assertEq(imd.balanceOf(address(sale)), 2 ether);
        vm.expectRevert(DerbyAuction.WrongStatus.selector);
        sale.settle(DAY);
        vm.expectRevert(DerbyAuction.BidClosed.selector);
        sale.bid(DAY, 3 ether, _answers());
    }

    function test_settleOneIMDFeeAndSettingsApplyOnlyAtSettlement() public {
        _bid(DAY, alice, 2 ether);
        sale.setBuildFee(1 ether);
        sale.setStudio(carol);
        vm.warp(_end(DAY));
        sale.settle(DAY);
        assertEq(imd.balanceOf(carol), 1 ether);
        assertEq(imd.balanceOf(studio), 0);
        assertEq(_state(DAY).bonus, 1 ether);
        assertEq(imd.balanceOf(address(sale)), 1 ether);
        sale.setBuildFee(0);
        sale.setStudio(studio);
        assertEq(_state(DAY).bonus, 1 ether);
    }

    function test_emptyAuctionSettlesWithoutTakingCarry() public {
        _settled(2 ether);
        _close(DAY);
        _pay(DAY);
        assertEq(sale.carry(), 2 ether);
        sale.settle(DAY + 1);
        assertTrue(_state(DAY + 1).settled);
        assertEq(_state(DAY + 1).leader, address(0));
        assertEq(_state(DAY + 1).bonus, 0);
        assertEq(sale.carryIn(DAY + 1), 0);
        assertEq(sale.carry(), 2 ether);
        vm.expectRevert(DerbyAuction.WrongStatus.selector);
        sale.settle(DAY + 1);
        vm.expectRevert(DerbyAuction.WrongStatus.selector);
        sale.payBonus(DAY + 1);
    }

    function test_failedStudioPaymentLeavesAuctionUnsettled() public {
        sale.setBuildFee(1 ether);
        _bid(DAY, alice, 2 ether);
        vm.warp(_end(DAY));
        imd.setFailure(studio, 1);
        vm.expectRevert(DerbyAuction.TransferFailed.selector);
        sale.settle(DAY);
        assertFalse(_state(DAY).settled);
        assertEq(_state(DAY).bonus, 0);
        sale.setStudio(carol);
        sale.settle(DAY);
        assertEq(imd.balanceOf(carol), 1 ether);
    }

    function test_realSwingsPayOnlyAfterArcadeDayClosedAndOnlyTopThree() public {
        _settled(10 ether);
        vm.warp(DAY * 1 days);
        _board(4);
        (address[] memory players, uint256[] memory scores) = derby.board(0, DAY);
        assertEq(players.length, 4);
        for (uint256 i = 1; i < scores.length; ++i) {
            assertGe(scores[i - 1], scores[i]);
        }
        vm.expectRevert(DerbyAuction.DayNotClosed.selector);
        sale.payBonus(DAY);
        vm.warp((DAY + 1) * 1 days);
        uint256 last = derby.dayLastTarget(0, DAY);
        arb.setBlock(last + 255);
        assertFalse(derby.dayClosed(0, DAY));
        vm.expectRevert(DerbyAuction.DayNotClosed.selector);
        sale.payBonus(DAY);
        assertFalse(_state(DAY).paid);
        arb.setBlock(last + 256);
        assertTrue(derby.dayClosed(0, DAY));
        assertEq(derby.settledDays(0), 0); // closure does not require the game's pot to be paid
        address[] memory winners = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            winners[i] = players[i];
        }
        amounts[0] = 5.97 ether;
        amounts[1] = 2.4875 ether;
        amounts[2] = 1.4925 ether;
        vm.expectEmit(true, false, false, true, address(sale));
        emit DerbyAuction.BonusPaid(DAY, winners, amounts, payer, 0.05 ether, 0);
        _pay(DAY);
        assertEq(imd.balanceOf(payer), 0.05 ether);
        for (uint256 i; i < 3; ++i) {
            assertEq(imd.balanceOf(players[i]), amounts[i]);
        }
        assertEq(imd.balanceOf(players[3]), 0);
        assertEq(sale.carry(), 0);
        assertEq(imd.balanceOf(address(sale)), 0);
        assertTrue(_state(DAY).paid);
        assertEq(_state(DAY).bonus, 0);
        vm.expectRevert(DerbyAuction.WrongStatus.selector);
        sale.payBonus(DAY);
    }

    function test_agentScoresAndOtherDaysNeverAffectArcadeBonus() public {
        _settled(2 ether);
        vm.warp(DAY * 1 days);
        _homer(0, alice, DerbyOdds.HOMER);
        _homer(1, bob, DerbyOdds.BOMB);
        _homer(1, bob, DerbyOdds.BOMB);
        assertGt(derby.dayScore(1, DAY, bob), derby.dayScore(0, DAY, alice));
        _close(DAY);
        _homer(0, carol, DerbyOdds.BOMB); // tomorrow's arcade board also has no influence
        uint256 aliceBefore = imd.balanceOf(alice);
        _pay(DAY);
        assertEq(imd.balanceOf(alice) - aliceBefore, 1.194 ether);
        assertEq(imd.balanceOf(bob), 0);
        assertEq(imd.balanceOf(carol), 0);
        assertEq(sale.carry(), 0.796 ether);
    }

    function _shortBoard(uint256 n, uint256 expectedCarry) internal {
        _settled(2 ether);
        vm.warp(DAY * 1 days);
        _board(n);
        _close(DAY);
        _pay(DAY);
        assertEq(sale.carry(), expectedCarry);
        assertEq(imd.balanceOf(payer), 0.01 ether);
        uint256 next = DAY + 3;
        vm.warp(_start(next));
        _bid(next, bob, 3 ether);
        vm.warp(_end(next));
        sale.settle(next);
        assertEq(sale.carryIn(next), expectedCarry);
        assertEq(_state(next).bonus, 3 ether + expectedCarry);
        assertEq(sale.carry(), 0);
    }

    function test_onePlayerCarriesUnfilledSharesIntoNextAuction() public {
        _shortBoard(1, 0.796 ether);
    }

    function test_twoPlayersCarryUnfilledShareIntoNextAuction() public {
        _shortBoard(2, 0.2985 ether);
    }

    function test_emptyArcadeWithAgentPlayersCarriesEverythingWithoutTip() public {
        _settled(2 ether);
        vm.warp(DAY * 1 days);
        _homer(1, bob, DerbyOdds.BOMB);
        _close(DAY);
        _pay(DAY);
        assertEq(imd.balanceOf(payer), 0);
        assertEq(imd.balanceOf(bob), 0);
        assertEq(sale.carry(), 2 ether);
        uint256 next = DAY + 3;
        vm.warp(_start(next));
        _bid(next, carol, 3 ether);
        vm.warp(_end(next));
        sale.settle(next);
        assertEq(_state(next).bonus, 5 ether);
        assertEq(sale.carryIn(next), 2 ether);
        assertEq(sale.carry(), 0);
    }

    function test_failedPrizeAndRoundingDustCarryWithoutBlockingOthers() public {
        uint256 bonus = 2 ether + 7;
        _settled(bonus);
        vm.warp(DAY * 1 days);
        _board(3);
        _close(DAY);
        (address[] memory players,) = derby.board(0, DAY);
        imd.setFailure(players[1], 4);
        _pay(DAY);
        uint256 tip = bonus * 50 / 10_000;
        uint256 rest = bonus - tip;
        assertEq(imd.balanceOf(players[0]), rest * 6000 / 10_000);
        assertEq(imd.balanceOf(players[1]), 0);
        assertEq(imd.balanceOf(players[2]), rest * 1500 / 10_000);
        uint256 expected = bonus - tip - rest * 6000 / 10_000 - rest * 1500 / 10_000;
        assertEq(sale.carry(), expected);
        assertEq(imd.balanceOf(address(sale)), expected);
    }

    function test_failedTipRevertsAndAnotherCallerCanPay() public {
        _settled(2 ether);
        vm.warp(DAY * 1 days);
        _board(1);
        _close(DAY);
        imd.setFailure(payer, 1);
        vm.prank(payer);
        vm.expectRevert(DerbyAuction.TransferFailed.selector);
        sale.payBonus(DAY);
        assertFalse(_state(DAY).paid);
        assertEq(_state(DAY).bonus, 2 ether);
        assertEq(sale.carry(), 0);
        sale.payBonus(DAY);
        assertEq(imd.balanceOf(address(this)), 0.01 ether);
    }

    // Fund a later auction with carry from an empty, real arcade day.
    function _withCarry() internal returns (uint256 next) {
        _settled(4 ether);
        _close(DAY);
        _pay(DAY);
        next = DAY + 3;
        vm.warp(_start(next));
        _bid(next, bob, 3 ether);
        sale.setBuildFee(1 ether);
        vm.warp(_end(next));
        sale.settle(next);
        assertEq(_state(next).bonus, 6 ether);
        assertEq(sale.carryIn(next), 4 ether);
        assertEq(imd.balanceOf(studio), 1 ether);
    }

    function test_vetoOwnerOnlyBeforeThemeDayReturnsOwnNetBidNotCarry() public {
        uint256 next = _withCarry();
        vm.prank(bob);
        vm.expectRevert(DerbyAuction.NotOwner.selector);
        sale.veto(next);
        vm.warp(next * 1 days - 1);
        vm.expectEmit(true, true, false, true, address(sale));
        emit DerbyAuction.Vetoed(next, bob, 2 ether);
        sale.veto(next);
        assertEq(imd.balanceOf(bob), 2 ether);
        assertEq(sale.carry(), 4 ether);
        assertEq(_state(next).bonus, 0);
        assertTrue(_state(next).vetoed);
        assertEq(imd.balanceOf(address(sale)), 4 ether);
        vm.expectRevert(DerbyAuction.WrongStatus.selector);
        sale.veto(next);
        vm.expectRevert(DerbyAuction.WrongStatus.selector);
        sale.payBonus(next);
        vm.warp(_grace(next) + 1);
        vm.expectRevert(DerbyAuction.WrongStatus.selector);
        sale.reclaim(next);
    }

    function test_vetoRejectsUnsettledEmptyAndThemeDayBoundary() public {
        vm.expectRevert(DerbyAuction.WrongStatus.selector);
        sale.veto(DAY);
        _bid(DAY, alice, 2 ether);
        vm.expectRevert(DerbyAuction.WrongStatus.selector);
        sale.veto(DAY);
        vm.warp(_end(DAY));
        sale.settle(DAY);
        vm.warp(DAY * 1 days);
        vm.expectRevert(DerbyAuction.BidClosed.selector);
        sale.veto(DAY);
        vm.warp(_end(DAY + 1));
        sale.settle(DAY + 1);
        vm.expectRevert(DerbyAuction.WrongStatus.selector);
        sale.veto(DAY + 1);
    }

    function test_zeroFeeVetoRefundsFullBidAndBlockedWinnerGetsCredit() public {
        _settled(2 ether);
        imd.setFailure(alice, 1);
        sale.veto(DAY);
        assertEq(sale.refunds(alice), 2 ether);
        assertEq(_state(DAY).bonus, 0);
        imd.setFailure(alice, 0);
        vm.prank(alice);
        sale.withdrawRefund();
        assertEq(imd.balanceOf(alice), 2 ether);
    }

    function test_reclaimGraceBoundaryReturnsOwnNetBidNotCarryToWinner() public {
        uint256 next = _withCarry();
        vm.expectRevert(DerbyAuction.TooEarly.selector);
        sale.reclaim(next);
        vm.warp(_grace(next));
        vm.expectRevert(DerbyAuction.TooEarly.selector);
        sale.reclaim(next);
        vm.warp(_grace(next) + 1);
        vm.expectEmit(true, true, false, true, address(sale));
        emit DerbyAuction.Reclaimed(next, bob, 2 ether);
        vm.prank(carol);
        sale.reclaim(next);
        assertEq(imd.balanceOf(carol), 0);
        assertEq(imd.balanceOf(bob), 2 ether);
        assertEq(sale.carry(), 4 ether);
        assertEq(_state(next).bonus, 0);
        assertTrue(_state(next).paid);
        vm.expectRevert(DerbyAuction.WrongStatus.selector);
        sale.reclaim(next);
        vm.expectRevert(DerbyAuction.WrongStatus.selector);
        sale.payBonus(next);
        assertEq(imd.balanceOf(address(sale)), 4 ether);
    }

    function test_reclaimRejectsUnsettledEmptyAndAlreadyPaidAuctions() public {
        _settled(2 ether);
        _close(DAY);
        _pay(DAY);
        vm.warp(_grace(DAY) + 1);
        vm.expectRevert(DerbyAuction.WrongStatus.selector);
        sale.reclaim(DAY);
        vm.expectRevert(DerbyAuction.WrongStatus.selector);
        sale.reclaim(DAY + 1);
        sale.settle(DAY + 1);
        vm.expectRevert(DerbyAuction.WrongStatus.selector);
        sale.reclaim(DAY + 1);
    }

    function test_blockedReclaimIsCreditedAndCarryIsReusable() public {
        uint256 next = _withCarry();
        vm.warp(_grace(next) + 1);
        imd.setFailure(bob, 2);
        sale.reclaim(next);
        assertEq(sale.refunds(bob), 2 ether);
        uint256 later = sale.openDay();
        _bid(later, carol, 2 ether);
        vm.warp(_end(later));
        sale.settle(later);
        assertEq(sale.carryIn(later), 4 ether);
        assertEq(_state(later).bonus, 5 ether);
        imd.setFailure(bob, 0);
        vm.prank(bob);
        sale.withdrawRefund();
        assertEq(imd.balanceOf(bob), 2 ether);
        assertEq(imd.balanceOf(address(sale)), 5 ether);
    }

    function test_adminPermissionsFeeCapAndTwoStepOwnership() public {
        vm.prank(alice);
        vm.expectRevert(DerbyAuction.NotOwner.selector);
        sale.setBuildFee(0);
        vm.prank(alice);
        vm.expectRevert(DerbyAuction.NotOwner.selector);
        sale.setStudio(alice);
        vm.prank(alice);
        vm.expectRevert(DerbyAuction.NotOwner.selector);
        sale.transferOwnership(alice);
        vm.expectRevert(DerbyAuction.ZeroAddress.selector);
        sale.setStudio(address(0));
        vm.expectRevert(DerbyAuction.BadFee.selector);
        sale.setBuildFee(1 ether + 1);
        vm.expectRevert(DerbyAuction.BadFee.selector);
        sale.setBuildFee(type(uint256).max);
        sale.transferOwnership(alice);
        assertEq(sale.owner(), address(this));
        assertEq(sale.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert(DerbyAuction.NotOwner.selector);
        sale.acceptOwnership();
        sale.transferOwnership(address(0));
        vm.prank(alice);
        vm.expectRevert(DerbyAuction.NotOwner.selector);
        sale.acceptOwnership();
        assertEq(sale.owner(), address(this));
        sale.transferOwnership(alice);
        vm.prank(alice);
        sale.acceptOwnership();
        assertEq(sale.owner(), alice);
        assertEq(sale.pendingOwner(), address(0));
        vm.expectRevert(DerbyAuction.NotOwner.selector);
        sale.setBuildFee(0);
        vm.prank(alice);
        sale.setBuildFee(1 ether);
        vm.prank(alice);
        sale.setStudio(bob);
        assertEq(sale.buildFee(), 1 ether);
        assertEq(sale.studio(), bob);
    }

    function test_noReturnTokenBidsRefundsFeesWithdrawalsAndBonus() public {
        imd.setNoReturn(true);
        _bid(DAY, alice, 2 ether);
        _bid(DAY, bob, 3 ether);
        assertEq(imd.balanceOf(alice), 2 ether);
        imd.setFailure(bob, 1);
        _bid(DAY, carol, 4 ether);
        imd.setFailure(bob, 0);
        vm.prank(bob);
        sale.withdrawRefund();
        assertEq(imd.balanceOf(bob), 3 ether);
        sale.setBuildFee(1 ether);
        vm.warp(_end(DAY));
        sale.settle(DAY);
        assertEq(imd.balanceOf(studio), 1 ether);
        vm.warp(DAY * 1 days);
        _board(1);
        _close(DAY);
        _pay(DAY);
        assertEq(imd.balanceOf(payer), 0.015 ether);
        assertEq(imd.balanceOf(_player(0)), 1.791 ether);
        assertEq(sale.carry(), 1.194 ether);
    }

    function test_failedOrShortTokenPullRollsBackBidAndAnswers() public {
        _fund(alice, 2 ether);
        for (uint8 mode = 1; mode <= 4; ++mode) {
            imd.setPullFailure(mode);
            vm.prank(alice);
            vm.expectRevert(DerbyAuction.TransferFailed.selector);
            sale.bid(DAY, 2 ether, _answers());
            assertEq(_state(DAY).leader, address(0));
        }
        imd.setPullFailure(0);
        imd.setShortfall(1);
        vm.prank(alice);
        vm.expectRevert(DerbyAuction.TransferFailed.selector);
        sale.bid(DAY, 2 ether, _answers());
        assertEq(_state(DAY).amount, 0);
        assertEq(bytes(sale.answers(DAY).creature).length, 0);
        assertEq(imd.balanceOf(alice), 2 ether);
        assertEq(imd.balanceOf(address(sale)), 0);
    }

    function test_reentrantTokenCannotBidOrWithdrawDuringTransfers() public {
        imd.setCallback(address(sale), abi.encodeCall(DerbyAuction.bid, (DAY, 3 ether, _answers())));
        _bid(DAY, alice, 2 ether);
        assertFalse(imd.callbackSucceeded());
        assertEq(imd.callbackResult(), abi.encodeWithSelector(DerbyAuction.ReentrantCall.selector));
        imd.setFailure(alice, 1);
        _bid(DAY, bob, 3 ether);
        imd.setFailure(alice, 0);
        imd.setCallback(address(sale), abi.encodeCall(DerbyAuction.withdrawRefund, ()));
        vm.prank(alice);
        sale.withdrawRefund();
        assertFalse(imd.callbackSucceeded());
        assertEq(imd.callbackResult(), abi.encodeWithSelector(DerbyAuction.ReentrantCall.selector));
        assertEq(sale.refunds(alice), 0);
        assertEq(imd.balanceOf(address(sale)), 3 ether);
    }

    function test_reentrantBonusAndReclaimCannotPayTwice() public {
        _settled(2 ether);
        vm.warp(DAY * 1 days);
        _board(1);
        _close(DAY);
        imd.setCallback(address(sale), abi.encodeCall(DerbyAuction.payBonus, (DAY)));
        _pay(DAY);
        assertFalse(imd.callbackSucceeded());
        assertEq(imd.callbackResult(), abi.encodeWithSelector(DerbyAuction.ReentrantCall.selector));
        assertEq(imd.balanceOf(payer), 0.01 ether);
        uint256 next = DAY + 3;
        vm.warp(_start(next));
        _bid(next, bob, 2 ether);
        vm.warp(_end(next));
        sale.settle(next);
        vm.warp(_grace(next) + 1);
        imd.setCallback(address(sale), abi.encodeCall(DerbyAuction.reclaim, (next)));
        sale.reclaim(next);
        assertFalse(imd.callbackSucceeded());
        assertEq(imd.callbackResult(), abi.encodeWithSelector(DerbyAuction.ReentrantCall.selector));
        assertEq(imd.balanceOf(bob), 2 ether);
        assertEq(imd.balanceOf(address(sale)), 0.796 ether);
    }

    function test_maximumBidSettlesAndPaysWithoutIntermediateOverflow() public {
        uint256 amount = type(uint256).max;
        _settled(amount);
        vm.warp(DAY * 1 days);
        _board(3);
        _close(DAY);
        _pay(DAY);
        uint256 tip = amount / 200;
        uint256 rest = amount - tip;
        uint256 first = rest / 10_000 * 6000 + rest % 10_000 * 6000 / 10_000;
        uint256 second = rest / 4;
        uint256 third = rest / 10_000 * 1500 + rest % 10_000 * 1500 / 10_000;
        (address[] memory players,) = derby.board(0, DAY);
        assertEq(imd.balanceOf(players[0]), first);
        assertEq(imd.balanceOf(players[1]), second);
        assertEq(imd.balanceOf(players[2]), third);
        assertEq(imd.balanceOf(payer), tip);
        assertEq(imd.balanceOf(address(sale)), amount - tip - first - second - third);
        assertEq(sale.carry(), imd.balanceOf(address(sale)));
    }

    /// Sum obligations independently of the token's actual balance after each operation.
    function _conserved(uint256[] memory days_) internal view {
        uint256 obligations = sale.carry() + sale.refunds(alice) + sale.refunds(bob) + sale.refunds(carol);
        for (uint256 i; i < days_.length; ++i) {
            DerbyAuction.Auction memory a = _state(days_[i]);
            if (!a.settled) obligations += a.amount;
            if (!a.paid && !a.vetoed) obligations += a.bonus;
            else assertEq(a.bonus, 0);
        }
        assertEq(imd.balanceOf(address(sale)), obligations, "IMD equals leads + unpaid bonuses + carry + refunds");
    }

    function testFuzz_conservationAcrossAuctionSequences(uint256 seed) public {
        uint256[] memory days_ = new uint256[](6);
        address[3] memory bidders = [alice, bob, carol];
        for (uint256 i; i < days_.length; ++i) {
            days_[i] = DAY + i * 10;
        }
        for (uint256 round; round < days_.length; ++round) {
            uint256 day = days_[round];
            vm.warp(_start(day));
            seed = uint256(keccak256(abi.encode(seed, round)));
            uint256 bids = seed % 6; // includes empty auctions
            for (uint256 j; j < bids; ++j) {
                seed = uint256(keccak256(abi.encode(seed, j)));
                address who = bidders[seed % 3];
                imd.setFailure(_state(day).leader, uint8((seed >> 8) % 5));
                if (j > 0 && seed % 2 == 0) vm.warp(_state(day).end - 1);
                _bid(day, who, sale.minNextBid(day) + (seed >> 16) % 1 ether);
                _conserved(days_);
            }
            sale.setBuildFee((seed >> 32) % (1 ether + 1));
            vm.warp(_state(day).end);
            sale.settle(day);
            _conserved(days_);
            uint256 action = (seed >> 64) % 4;
            if (bids > 0 && action == 0) {
                sale.veto(day);
                _conserved(days_);
            } else if (bids > 0 && action == 1) {
                vm.warp(_grace(day) + 1);
                sale.reclaim(day);
                _conserved(days_);
            } else if (bids > 0 && action == 2) {
                vm.warp(day * 1 days);
                uint256 players = (seed >> 96) % 5;
                _board(players);
                if (players > 0) imd.setFailure(_player((seed >> 104) % players), uint8((seed >> 112) % 5));
                _close(day);
                _pay(day);
                _conserved(days_);
                for (uint256 j; j < players; ++j) {
                    imd.setFailure(_player(j), 0);
                }
            } // action 3 leaves multiple unpaid bonuses outstanding
            for (uint256 j; j < 3; ++j) {
                imd.setFailure(bidders[j], 0);
                if (sale.refunds(bidders[j]) > 0 && (seed >> (j + 120)) % 2 == 0) {
                    vm.prank(bidders[j]);
                    sale.withdrawRefund();
                    _conserved(days_);
                }
            }
        }
        vm.warp(_grace(days_[5]) + 1);
        for (uint256 i; i < days_.length; ++i) {
            if (_state(days_[i]).bonus > 0) {
                sale.reclaim(days_[i]);
                _conserved(days_);
            }
        }
    }
}
