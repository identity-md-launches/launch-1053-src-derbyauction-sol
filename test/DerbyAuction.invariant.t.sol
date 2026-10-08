// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DerbyAuction, ISwarmDerby} from "src/DerbyAuction.sol";
import {IERC20} from "src/SwarmDerby.sol";
import {AuctionToken} from "./DerbyAuction.t.sol";

/// Offline dependencies reuse the accepted token mock; no token or game is deployed.
abstract contract AuctionOfflineTest is Test {
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant DERBY = 0xBa58BC6b5aCf8043DAEa2Bf1BF6C1c09cF84b03C;
    uint256 internal constant DAY = 20_400;
    AuctionToken internal token = AuctionToken(IMD);
    DerbyAuction internal auction;

    function setUp() public virtual {
        vm.chainId(31337);
        vm.warp((DAY - 2) * 1 days + 18 hours);
        auction = new DerbyAuction(address(this), IERC20(IMD), ISwarmDerby(DERBY), address(this), 0);
        vm.etch(IMD, type(AuctionToken).runtimeCode);
        vm.etch(DERBY, hex"00");
    }

    function state(uint256 day) internal view returns (DerbyAuction.Auction memory a) {
        (a.leader, a.amount, a.end, a.settled, a.vetoed, a.paid, a.bonus) = auction.auction(day);
    }

    function answers() internal pure returns (DerbyAuction.Answers memory) {
        return DerbyAuction.Answers("Fox", 0, 0, 0, "Race", "");
    }

    function bid(address bidder, uint256 day, uint256 amount) internal {
        token.mint(bidder, amount);
        vm.startPrank(bidder);
        token.approve(address(auction), amount);
        auction.bid(day, amount, answers());
        vm.stopPrank();
    }

    function board(uint256 day, address[] memory players) internal {
        vm.mockCall(DERBY, abi.encodeCall(ISwarmDerby.dayClosed, (0, day)), abi.encode(true));
        vm.mockCall(
            DERBY, abi.encodeCall(ISwarmDerby.board, (0, day)), abi.encode(players, new uint256[](players.length))
        );
    }
}

contract DerbyAuctionBoundaryTest is AuctionOfflineTest {
    function test_deploymentUsesExactLaunchArgumentsOnEmptyChain() public {
        vm.etch(IMD, bytes(""));
        vm.etch(DERBY, bytes(""));
        vm.expectCall(IMD, bytes(""), uint64(0));
        vm.expectCall(DERBY, bytes(""), uint64(0));
        DerbyAuction deployed = new DerbyAuction(address(this), IERC20(IMD), ISwarmDerby(DERBY), address(this), 0);
        assertEq(deployed.owner(), address(this));
        assertEq(deployed.studio(), address(this));
        assertEq(address(deployed.imd()), IMD);
        assertEq(address(deployed.derby()), DERBY);
        assertEq(deployed.buildFee(), 0);
        vm.expectRevert(DerbyAuction.NotAContract.selector);
        deployed.bid(DAY, 2 ether, answers());
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_minimumIncrementIsSmallestWholeWeiAtLeastFivePercent(uint256 amount) public {
        amount = bound(amount, 2 ether, type(uint128).max);
        bid(makeAddr("bidder"), DAY, amount);
        uint256 next = auction.minNextBid(DAY);
        // Independent inequalities prove both sufficiency and minimality without copying _bps.
        assertGe(next * 100, amount * 105);
        assertLt((next - 1) * 100, amount * 105);
        vm.expectRevert(DerbyAuction.BidTooLow.selector);
        auction.bid(DAY, next - 1, answers());
        bid(makeAddr("challenger"), DAY, next);
        assertEq(state(DAY).amount, next);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_failedReplacementPreservesLeaderAnswersDeadlineAndBalances(uint256 raw, uint8 mode) public {
        address bidder = makeAddr("first");
        address challenger = makeAddr("second");
        uint256 amount = bound(raw, 2 ether, 1e30);
        bid(bidder, DAY, amount);
        vm.warp(state(DAY).end - 1); // A successful call would also extend the end.
        bytes memory beforeState = abi.encode(state(DAY));
        bytes memory beforeAnswers = abi.encode(auction.answers(DAY));
        uint256 replacement = auction.minNextBid(DAY);
        token.mint(challenger, replacement);
        vm.prank(challenger);
        token.approve(address(auction), replacement);
        token.setPullFailure(uint8(bound(mode, 1, 4)));
        vm.prank(challenger);
        vm.expectRevert(DerbyAuction.TransferFailed.selector);
        auction.bid(DAY, replacement, DerbyAuction.Answers("Owl", 3, 5, 5, "New race", "Hi"));
        assertEq(abi.encode(state(DAY)), beforeState);
        assertEq(abi.encode(auction.answers(DAY)), beforeAnswers);
        assertEq(token.balanceOf(address(auction)), amount);
        assertEq(token.balanceOf(challenger), replacement);
        assertEq(token.allowance(challenger, address(auction)), replacement);
        assertEq(auction.refunds(bidder), 0);
        token.setPullFailure(0);
        vm.prank(challenger);
        auction.bid(DAY, replacement, answers()); // The reentrancy lock must also roll back.
        assertEq(token.balanceOf(bidder), amount);
    }

    function test_boardReadRevertRollsBackPaidFlagAndAllowsRetry() public {
        bid(makeAddr("bidder"), DAY, 2 ether);
        vm.warp(state(DAY).end);
        auction.settle(DAY);
        vm.mockCall(DERBY, abi.encodeCall(ISwarmDerby.dayClosed, (0, DAY)), abi.encode(true));
        vm.mockCallRevert(
            DERBY,
            abi.encodeCall(ISwarmDerby.board, (0, DAY)),
            abi.encodeWithSignature("Error(string)", "board unavailable")
        );
        vm.expectRevert("board unavailable");
        auction.payBonus(DAY);
        assertFalse(state(DAY).paid);
        assertEq(state(DAY).bonus, 2 ether);
        assertEq(auction.carry(), 0);
        assertEq(token.balanceOf(address(auction)), 2 ether);
        vm.clearMockedCalls();
        board(DAY, new address[](0));
        auction.payBonus(DAY);
        assertTrue(state(DAY).paid);
        assertEq(auction.carry(), 2 ether);
    }

    function test_lateSettlementCannotTakeCarryReservedForFutureThemeDay() public {
        address bidder = makeAddr("bidder");
        bid(bidder, DAY, 2 ether);
        vm.warp(state(DAY).end);
        auction.settle(DAY);
        vm.warp((DAY + 1) * 1 days);
        board(DAY, new address[](0));
        auction.payBonus(DAY);
        uint256 next = DAY + 3;
        vm.warp((next - 2) * 1 days + 18 hours);
        bid(bidder, next, 3 ether);
        vm.warp(next * 1 days); // Exactly the theme-day boundary is already late.
        auction.settle(next);
        assertEq(auction.carryIn(next), 0);
        assertEq(state(next).bonus, 3 ether);
        assertEq(auction.carry(), 2 ether);
        vm.warp((next + 1) * 1 days + 7 days + 1);
        auction.reclaim(next);
        assertEq(token.balanceOf(bidder), 3 ether);
        assertEq(token.balanceOf(address(auction)), 2 ether);
        assertEq(auction.carry(), 2 ether);
    }
}

/// Random operations span several auctions and actors. Expected failures are checked explicitly;
/// any other revert (including assertion failures) fails the invariant campaign.
contract AuctionSequenceHandler is Test {
    DerbyAuction public immutable auction;
    AuctionToken public immutable token;
    address public immutable derby;
    address[5] public actors;
    uint256[] public auctionDays;
    mapping(uint256 => bool) private tracked;
    mapping(uint256 => bool) public wasSettled;
    mapping(uint256 => bool) public wasPaid;
    mapping(uint256 => bool) public wasVetoed;
    uint256 public totalFunded;
    uint256 public donations;
    uint256 public successfulBids;
    uint256 public successfulSettlements;
    uint256 public successfulTerminations;

    constructor(DerbyAuction auction_) {
        auction = auction_;
        token = AuctionToken(address(auction_.imd()));
        derby = address(auction_.derby());
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("sequence actor ", vm.toString(i)));
        }
    }

    function _state(uint256 day) internal view returns (DerbyAuction.Auction memory a) {
        (a.leader, a.amount, a.end, a.settled, a.vetoed, a.paid, a.bonus) = auction.auction(day);
    }

    function _track(uint256 day) internal {
        if (!tracked[day]) {
            tracked[day] = true;
            auctionDays.push(day);
        }
    }

    function _attempt(address caller, bytes memory data, bytes4 expectedError) internal returns (bool ok) {
        vm.prank(caller);
        bytes memory result;
        (ok, result) = address(auction).call(data);
        if (expectedError == bytes4(0)) {
            assertTrue(ok, "valid auction operation must succeed");
        } else {
            assertFalse(ok, "invalid auction operation must fail");
            assertEq(result, abi.encodeWithSelector(expectedError), "unexpected auction failure");
        }
        _checkTerminalStates();
    }

    function _refundable(DerbyAuction.Auction memory a) internal pure returns (bool) {
        return a.settled && a.leader != address(0) && !a.vetoed && !a.paid && a.bonus > 0;
    }

    function _checkTerminalStates() internal {
        for (uint256 i; i < auctionDays.length; ++i) {
            uint256 day = auctionDays[i];
            DerbyAuction.Auction memory a = _state(day);
            if (wasSettled[day]) assertTrue(a.settled, "settlement reopened");
            if (wasPaid[day]) assertTrue(a.paid, "payment reopened");
            if (wasVetoed[day]) assertTrue(a.vetoed, "veto reopened");
            wasSettled[day] = a.settled;
            wasPaid[day] = a.paid;
            wasVetoed[day] = a.vetoed;
        }
    }

    function bidNow(uint256 actorSeed, uint256 extra) public {
        uint256 day = auction.openDay();
        _track(day);
        address who = actors[actorSeed % actors.length];
        uint256 amount = auction.minNextBid(day) + bound(extra, 0, 10 ether);
        token.mint(who, amount);
        totalFunded += amount;
        vm.startPrank(who);
        token.approve(address(auction), amount);
        auction.bid(day, amount, DerbyAuction.Answers("Fox", 0, 0, 0, "Race", ""));
        vm.stopPrank();
        ++successfulBids;
        _checkTerminalStates();
    }

    function advance(uint256 rawSeconds, uint256 daySeed, uint8 boundary) public {
        uint256 next = block.timestamp + bound(rawSeconds, 1, 12 hours);
        if (auctionDays.length > 0 && boundary % 4 != 0) {
            uint256 day = auctionDays[daySeed % auctionDays.length];
            if (boundary % 4 == 1) next = _state(day).end;
            if (boundary % 4 == 2) next = (day + 1) * 1 days;
            if (boundary % 4 == 3) {
                uint256 from = (day + 1) * 1 days;
                if (auction.settledAt(day) > from) from = auction.settledAt(day);
                next = from + 7 days + 1;
            }
        }
        if (next > block.timestamp) vm.warp(next);
    }

    function settle(uint256 seed) public {
        if (auctionDays.length == 0) _track(auction.openDay());
        uint256 day = auctionDays[seed % auctionDays.length];
        DerbyAuction.Auction memory a = _state(day);
        bytes4 expected = a.settled
            ? DerbyAuction.WrongStatus.selector
            : block.timestamp < a.end ? DerbyAuction.TooEarly.selector : bytes4(0);
        if (_attempt(actors[seed % 5], abi.encodeCall(DerbyAuction.settle, (day)), expected)) ++successfulSettlements;
    }

    function terminate(uint256 seed, uint8 kind, uint8 boardSize, uint256 payerSeed) public {
        if (auctionDays.length == 0) return;
        uint256 day = auctionDays[seed % auctionDays.length];
        DerbyAuction.Auction memory a = _state(day);
        uint256 winnerClaim = token.balanceOf(a.leader) + auction.refunds(a.leader);
        bytes4 expected = _refundable(a) ? bytes4(0) : DerbyAuction.WrongStatus.selector;
        bool ok;
        if (kind % 3 == 0) {
            if (expected == bytes4(0) && block.timestamp >= day * 1 days) expected = DerbyAuction.BidClosed.selector;
            ok = _attempt(address(this), abi.encodeCall(DerbyAuction.veto, (day)), expected);
        } else if (kind % 3 == 1) {
            uint256 from = (day + 1) * 1 days;
            if (auction.settledAt(day) > from) from = auction.settledAt(day);
            if (expected == bytes4(0) && block.timestamp <= from + 7 days) expected = DerbyAuction.TooEarly.selector;
            ok = _attempt(actors[payerSeed % 5], abi.encodeCall(DerbyAuction.reclaim, (day)), expected);
        } else {
            address[] memory players = new address[](boardSize % 5);
            for (uint256 i; i < players.length; ++i) {
                players[i] = actors[i];
            }
            vm.mockCall(
                derby,
                abi.encodeCall(ISwarmDerby.dayClosed, (0, day)),
                abi.encode(block.timestamp >= (day + 1) * 1 days)
            );
            vm.mockCall(
                derby, abi.encodeCall(ISwarmDerby.board, (0, day)), abi.encode(players, new uint256[](players.length))
            );
            if (expected == bytes4(0)) {
                if (block.timestamp < (day + 1) * 1 days) {
                    expected = DerbyAuction.DayNotClosed.selector;
                } else if (players.length > 0 && a.bonus / 200 > 0 && token.failure(actors[payerSeed % 5]) != 0) {
                    expected = DerbyAuction.TransferFailed.selector;
                }
            }
            ok = _attempt(actors[payerSeed % 5], abi.encodeCall(DerbyAuction.payBonus, (day)), expected);
        }
        if (ok) {
            ++successfulTerminations;
            if (kind % 3 < 2) {
                uint256 returned = token.balanceOf(a.leader) + auction.refunds(a.leader) - winnerClaim;
                assertEq(returned, a.bonus - auction.carryIn(day), "winner can recover only their own net bid");
            }
        }
    }

    function withdraw(uint256 seed) public {
        address who = actors[seed % 5];
        uint256 credit = auction.refunds(who);
        uint256 balance = token.balanceOf(who);
        bytes4 expected = credit == 0
            ? DerbyAuction.NoRefund.selector
            : token.failure(who) != 0 ? DerbyAuction.TransferFailed.selector : bytes4(0);
        if (_attempt(who, abi.encodeCall(DerbyAuction.withdrawRefund, ()), expected)) {
            assertEq(token.balanceOf(who) - balance, credit, "withdrawal returns the full credit");
            assertEq(auction.refunds(who), 0, "withdrawal cannot be repeated");
        }
    }

    function configure(uint256 fee, uint256 studioSeed) public {
        auction.setBuildFee(bound(fee, 0, 1 ether));
        auction.setStudio(actors[studioSeed % 5]);
    }

    function transferFailure(uint256 actorSeed, uint8 mode, bool noReturn) public {
        token.setFailure(actors[actorSeed % 5], uint8(bound(mode, 0, 4)));
        token.setNoReturn(noReturn);
    }

    function donate(uint256 amount, uint256 actorSeed) public {
        amount = bound(amount, 0, 1 ether);
        address who = actors[actorSeed % 5];
        token.mint(who, amount);
        totalFunded += amount;
        vm.prank(who);
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.transfer, (address(auction), amount)));
        assertTrue(ok);
        donations += amount;
    }

    function dayCount() external view returns (uint256) {
        return auctionDays.length;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract DerbyAuctionInvariantTest is AuctionOfflineTest {
    AuctionSequenceHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new AuctionSequenceHandler(auction);
        auction.transferOwnership(address(handler));
        vm.prank(address(handler));
        auction.acceptOwnership();
        handler.configure(0, 4);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.bidNow.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.terminate.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.configure.selector;
        selectors[6] = handler.transferFailure.selector;
        selectors[7] = handler.donate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// Exact custody identity: active leads + unpaid bonuses + credits + carry, plus donations.
    function invariant_allObligationsRemainFullyBacked() public view {
        uint256 owed = auction.carry();
        for (uint256 i; i < 5; ++i) {
            owed += auction.refunds(handler.actors(i));
        }
        for (uint256 i; i < handler.dayCount(); ++i) {
            DerbyAuction.Auction memory a = state(handler.auctionDays(i));
            if (!a.settled) owed += a.amount;
            if (!a.vetoed && !a.paid) owed += a.bonus;
            else assertEq(a.bonus, 0, "terminal auction retains a payable bonus");
        }
        assertEq(
            token.balanceOf(address(auction)), owed + handler.donations(), "auction custody diverged from obligations"
        );
    }

    /// An independent ghost records only harness funding; transfers cannot create/destroy value.
    function invariant_noValueIsCreatedOrLost() public view {
        uint256 held = token.balanceOf(address(auction));
        for (uint256 i; i < 5; ++i) {
            held += token.balanceOf(handler.actors(i));
        }
        assertEq(held, handler.totalFunded());
    }

    function invariant_terminalStatesAndExtensionCapHold() public view {
        for (uint256 i; i < handler.dayCount(); ++i) {
            uint256 day = handler.auctionDays(i);
            DerbyAuction.Auction memory a = state(day);
            if (handler.wasSettled(day)) assertTrue(a.settled);
            if (handler.wasPaid(day)) assertTrue(a.paid);
            if (handler.wasVetoed(day)) assertTrue(a.vetoed);
            assertFalse(a.paid && a.vetoed);
            assertLe(a.end, (day - 1) * 1 days + 19 hours);
        }
    }

    function test_handlerExercisesCarryCreditsVetoReclaimAndWithdraw() public {
        handler.bidNow(0, 0);
        handler.transferFailure(0, 1, false);
        handler.bidNow(1, 0);
        handler.advance(1, 0, 1);
        handler.settle(0);
        handler.advance(1, 0, 2);
        handler.terminate(0, 2, 0, 2); // Empty board carries all of the bonus.
        assertGt(auction.carry(), 0);
        handler.bidNow(2, 0);
        handler.advance(1, 1, 1);
        handler.settle(1);
        assertGt(auction.carryIn(handler.auctionDays(1)), 0);
        handler.terminate(1, 0, 0, 0); // Veto restores carry, refunds only own bid.
        handler.advance(1, 1, 2);
        handler.bidNow(3, 0);
        handler.advance(1, 2, 1);
        handler.settle(2);
        handler.advance(1, 2, 3);
        handler.terminate(2, 1, 0, 4);
        handler.transferFailure(0, 0, true);
        handler.withdraw(0);
        assertEq(auction.refunds(handler.actors(0)), 0);
        assertEq(handler.successfulBids(), 4);
        assertEq(handler.successfulSettlements(), 3);
        assertEq(handler.successfulTerminations(), 3);
        invariant_allObligationsRemainFullyBacked();
        invariant_noValueIsCreatedOrLost();
        invariant_terminalStatesAndExtensionCapHold();
    }
}
