# deal-utils.tcl
# Procedures for use with the deal CLI hand genertor
# http://bridge.thomasoandrews.com/deal30/
#
# Personal custom bridge utils directory imported by using for example the environment variable BRIDGE_TCL_UTILS_DIR
# and then sourcing this file from another script:
# set bridge_tcl_utils_source $::env(BRIDGE_TCL_UTILS_DIR)
# set deal_utils_rel_path "/deal-utils.tcl"
# source $bridge_tcl_utils_source$deal_utils_rel_path
#
# Then example program:
# main {
#   if { [is_any_1c_opener north]} {accept}
#   reject
# }

# Imports for other helpers in the deal libraries: 5CM_nt etc.
source lib/utility.tcl

proc long_semi_solid {hand suit} {
  # AKQ are worth 2 points jack 10 1 point
  if { ([Top5Q $hand $suit] >=6) && ([$suit $hand]>=7)} { return 1 }
  return 0
}

proc good_6_plus_suit {hand suit} {
  # 2 top 3 honours type hand
  if { ([Top5Q $hand $suit] >=4) && ([$suit $hand]>=6)} { return 1 }
  return 0
}

proc any_good_6_plus_carder {hand} {
  if {[good_6_plus_suit $hand spades] || [good_6_plus_suit $hand hearts] || [good_6_plus_suit $hand diamonds] || [good_6_plus_suit $hand clubs]} { return 1 }
  return 0
}

proc flattish {hand} {
  if { [balanced $hand] || [semibalanced $hand] } { return 1 }
  return 0
}

proc two_suiter {hand} {
  set handshape [$hand pattern]
  if {$handshape == "5 5 2 1" || $handshape == "5 5 3 0" ||
      $handshape == "6 4 2 1" || $handshape == "6 4 3 0" ||
      $handshape == "6 5 2 0" || $handshape == "6 5 1 1" ||
      $handshape == "7 4 1 1" || $handshape == "7 4 2 0" ||
      $handshape == "7 5 1 0"} { return 1 }
  return 0
}

proc is_6_plus_other_10_card_two_suiter {hand} {
  set handshape [$hand pattern]
  if {$handshape == "6 4 2 1" || $handshape == "6 4 3 0" ||
      $handshape == "7 3 2 1" || $handshape == "7 3 3 0"} { return 1 }
  return 0
}

proc is_asymmetric_10_plus_two_suiter {hand} {
  set handshape [$hand pattern]
  if {
      $handshape == "6 4 2 1" || $handshape == "6 4 3 0" ||
      $handshape == "6 5 2 0" || $handshape == "6 5 1 1" ||
      $handshape == "7 4 1 1" || $handshape == "7 4 2 0" ||
      $handshape == "7 5 1 0" || $handshape == "8 4 1 0" } { return 1 }
  return 0
}

proc is_6_plus_other_11_or_more_card_two_suiter {hand} {
  set handshape [$hand pattern]
  if {$handshape == "6 5 2 0" || $handshape == "6 5 1 1" ||
      $handshape == "6 6 1 0" ||
      $handshape == "7 4 1 1" || $handshape == "7 4 2 0" ||
      $handshape == "7 5 1 0" || $handshape == "8 4 1 0"} { return 1 }
  return 0
}

proc majors_4_4 {hand} {
  if { [spades $hand]==4 && [hearts $hand]==4 } { return 1 }
  return 0
}

proc is_unbalanced_minor {hand} {
  set ds [diamonds $hand]
  set cs [clubs $hand]
  set hs [hearts $hand]
  set ss [spades $hand]
  if {![flattish $hand] && (($ds > $hs && $ds > $ss) || ($cs > $hs && $cs > $ss))} { return 1 }
  return 0
}

proc has_9_plus_majors {hand} {
  if { ([spades $hand] + [hearts $hand]) >= 9 } { return 1 }
  return 0
}

proc is_weak_1c {hand} {
  if {[5CM_nt $hand 13 15]} { return 1 } else { return 0 }
}

proc is_strong_1c {hand} {
  set points [hcp $hand]
  if { $points < 16 } { return 0}
  if { $points >= 21 } { return 1}

  if { [flattish $hand] } { return 0 } else { return 1}
}

proc is_any_1c_opener {hand} {
  if { [is_weak_1c $hand] || [is_strong_1c $hand] } { return 1}
  return 0
}

proc is_1d_unbal_opener {hand} {
  if { [flattish $hand] } { return 0 }
  set points [hcp $hand]
  if { $points <11 || $points>15 } { return 0 }
  if { [is_2c_opener $hand] || [is_2d_intermediate_opener $hand]} { return 0 }
  set ds [diamonds $hand]
  if { $ds<4 || [spades $hand]>=$ds || [hearts $hand]>=$ds } { return 0 }
  return 1
}

proc is_1d_opener {hand} {
  if { [is_1d_unbal_opener $hand] } { return 1 }
  if { [is_1major_opener $hand] } { return 0 }
  if { [5CM_nt $hand 11 13] } { return 1 } else { return 0 }
}

proc is_1major_opener {hand} {
  set points [hcp $hand]
  if { $points <11 || $points>15 } { return 0 }
  set hs [hearts $hand]
  set ss [spades $hand]
  if { $hs<5 && $ss<5 } { return 0 }
  if { [5CM_nt $hand 13 15] } { return 0 }
  set ds [diamonds $hand]
  set cs [clubs $hand]
  if { $cs>$hs && $cs>$ss} { return 0 }
  if { $ds>$hs && $ds>$ss} { return 0 }
  if { [is_3n_opener $hand]} { return 0 }
  return 1
}

proc is_1major_overcall {hand} {
  set points [hcp $hand]
  if { $points <8 || $points>16 } { return 0 }
  set hs [hearts $hand]
  set ss [spades $hand]
  if { $hs<5 && $ss<5 } { return 0 }

  set ds [diamonds $hand]
  set cs [clubs $hand]
  if { $cs>$hs && $cs>$ss} { return 0 }
  if { $ds>$hs && $ds>$ss} { return 0 }

  if {[5CM_nt $hand 15 18]} { return 0 }

  return 1
}

proc is_1d_takeout {hand} {
  set points [hcp $hand]
  if { $points <11  } { return 0 }

  if {[is_1major_overcall $hand]} { return 0}
  if {[5CM_nt $hand 15 18]} { return 0 }

  set ds [diamonds $hand]
  if { $ds >= 3 } { return 0 }

  return 1
}


proc has_major_support {opener_hand responder_hand support_length} {
  set ss [spades $opener_hand]
  set hs [hearts $opener_hand]
  set resp_s [spades $responder_hand]
  set resp_h [hearts $responder_hand]
  if { ($ss>=5 && $resp_s>=$support_length) ||
       ($hs>=5 && $resp_h>=$support_length) } { return 1 } else { return 0 }
}

proc is_1nt_opener {hand} {
  if {[5CM_nt $hand 16 18]} { return 1 } else { return 0 }
}

proc is_2nt_opener {hand} {
  if {[5CM_nt $hand 19 20]} { return 1 } else { return 0 }
}

proc is_marmic {hand} {
  if { [$hand pattern] == "4 4 4 1" } { return 1 } else { return 0 }
}

proc is_2c_opener {hand} {
  set points [hcp $hand]
  set clublen [clubs $hand]
  set min7carder [expr $points==10 && $clublen==7]
  set longOther [expr [spades $hand]>5 || [hearts $hand]>5 || [diamonds $hand]>5]

  if {!$longOther && ($min7carder || ($clublen>=6 && $points>=11)) && $points <= 15 } { return 1 }
  return 0
}

proc is_2d_opener {hand} {
  set points [hcp $hand]
  set shdc [$hand shape]
  if {$shdc == "4 4 1 4" && $points >= 12 && $points <= 16} { return 1 }
  if {($shdc=="4 4 0 5" || $shdc=="4 3 1 5" || $shdc=="3 4 1 5")
      && $points >= 11 && $points <= 15} { return 1 }
  return 0
}

proc is_2d_intermediate_opener {hand} {
  set points [hcp $hand]
  if {$points < 9 || $points > 15} { return 0 }

  # 6+ diamonds, longest suit (or maybe same length as clubs)
  # Not 6--5 with major
  set cs [clubs $hand]
  set ds [diamonds $hand]
  set hs [hearts $hand]
  set ss [spades $hand]
  if {$ds < 6 || $ds < $cs || $hs > 4 || $ss > 4 } { return 0 }

  # 9/10 hcp should have extra shape
  if {$points == 9 && ![is_6_plus_other_11_or_more_card_two_suiter $hand]} { return 0 }
  if {$points == 10 && ![is_6_plus_other_10_card_two_suiter $hand] && ![is_6_plus_other_11_or_more_card_two_suiter $hand] } { return 0 }

  return 1
}

proc has_side_major {hand} {
  if {[spades $hand]>=4 || [hearts $hand]>=4} { return 1 } else { return 0}
}

proc is_tricky_suit {hand suit} {
  if { [offense $hand $suit] > 3 } { return 1 } else { return 0 }
}

proc has_n_plus_carder {hand n} {
  if {[spades $hand] >= $n || [hearts $hand] >= $n || [diamonds $hand] >= $n || [clubs $hand] >= $n} { return 1 }
  return 0
}

proc is_any_weak_6_plus_carder {hand} {
  set points [hcp $hand]
  if {$points < 5 || $points > 11 } { return 0 }
  return [has_n_plus_carder $hand 6]
}

proc is_any_weak_or_min_7_plus_carder {hand} {
  set points [hcp $hand]
  if {$points < 5 || $points > 14 } { return 0 }
  return [has_n_plus_carder $hand 7]
}

proc is_generic_weak2d {hand} {
  set points [hcp $hand]
  if {$points<6 || $points>10 } { return 0 }

  set ss [spades $hand]
  set hs [hearts $hand]
  if {$ss>=4 || $hs >=4} {return 0}
  if {[diamonds $hand]==6 && [clubs $hand]<=5 && [Honors $hand diamonds]>=1} {return 1}
  return 0
}

proc is_generic_5card_unbal_weak2 {hand} {
  set points [hcp $hand]
  if {$points<6 || $points>10 } { return 0 }
  set handshape [$hand pattern]
  if {$handshape == "5 3 3 2"} { return 0}
  if {$handshape != "5 4 2 2" && $handshape != "5 4 3 1" && $handshape != "5 5 3 0" && $handshape != "5 5 2 1"} { return 0 }

  set ss [spades $hand]
  set hs [hearts $hand]
  set ds [diamonds $hand]
  set cs [clubs $hand]
  if {$ss>=4 && $hs >=4} {return 0}
  if {$ss==5 || $hs==5 || $ds==5} {return 1}
  return 0
}

proc is_weak2_5card_major {hand} {
  set points [hcp $hand]
  set handshape [$hand pattern]
  if {$points<6 || $points>11} { return 0 }
  if {$handshape == "5 3 3 2"} { return 0}

  if {$points<7 && $handshape != "5 5 3 0" && $handshape != "5 5 2 1"} { return 0 }
  if {$handshape != "5 4 2 2" && $handshape != "5 4 3 1" && $handshape != "5 5 3 0" && $handshape != "5 5 2 1"} { return 0 }

  set ss [spades $hand]
  set hs [hearts $hand]
  # no 6 card minor and no 4 card side major
  if {$ss>=4 && $hs >=4} {return 0}
  if {[diamonds $hand]>5 || [clubs $hand]>5} {return 0}

  # 5 cards and 2+ honors
  if {($ss==5 && [Honors $hand spades]>=2) || ($hs==5 && [Honors $hand hearts]>=2)} {return 1}
  return 0
}

proc is_weak2_major {hand} {
  set points [hcp $hand]
  set handshape [$hand pattern]
  if {$points<6 || $points>11 } { return 0 }
  # weaker hands need more shape
  if {$points<7 && $handshape != "6 4 2 1" && $handshape != "6 4 3 0"} { return 0 }
  # 6--5 hands should be < 10
  if {$points>9 && ($handshape == "6 5 1 1" || $handshape == "6 5 2 0")} { return 0 }

  set ss [spades $hand]
  set hs [hearts $hand]
  # no 4 card side major
  if {$ss>=4 && $hs >=4} {return 0}
  # no 6 card minor
  if {[diamonds $hand]>5 || [clubs $hand]>5} {return 0}

  # 6 cards and 1+ honors
  if {($ss==6 && [Honors $hand spades]>=1) || ($hs==6 && [Honors $hand hearts]>=1)} {return 1}
  return 0
}

proc is_weak_5_or_6_card_major {hand} {
  if { [is_weak2_major $hand] || [is_weak2_5card_major $hand] } { return 1 }
  return 0
}

proc is_semi_positive_weak_two_hearts {hand} {
  set points [hcp $hand]
  set handshape [$hand pattern]
  if {$points<4 || $points>7 } { return 0 }
  # weaker hands need more shape
  if {$points<5 && $handshape != "6 4 2 1" && $handshape != "6 4 3 0"} { return 0 }
  # 6--5 hands should be < 8
  if {$points>6 && ($handshape == "6 5 1 1" || $handshape == "6 5 2 0")} { return 0 }

  set ss [spades $hand]
  set hs [hearts $hand]
  # no 4 card side major
  if {$ss>=4 && $hs >=4} {return 0}

  # no 6 card minor
  if {[diamonds $hand]>5 || [clubs $hand]>5} {return 0}

  # 6 cards and 1+ honors
  if {$hs==6 && [Honors $hand hearts]>=1} {return 1}
  return 0
}

proc is_semi_positive_majors_two_suiter {hand} {
  if {![two_suiter $hand]} { return 0 }

  set hs [hearts $hand]
  set ss [spades $hand]
  if { $hs < 5 || $ss < 5 } { return 0 }

  set points [hcp $hand]
  if {$points<3 || $points>7 } { return 0 }

  set handshape [$hand pattern]
  if {$points<5 && $handshape != "6 5 1 1" && $handshape != "6 5 2 0"} { return 0 }

  return 1
}

proc is_gf_majors_two_suiter {hand} {
  if {![two_suiter $hand]} { return 0 }

  set hs [hearts $hand]
  set ss [spades $hand]
  if { $hs < 5 || $ss < 5 } { return 0 }

  set points [hcp $hand]
  if {$points<6} { return 0 }

  set handshape [$hand pattern]
  if {$points<7 && $handshape != "6 5 1 1" && $handshape != "6 5 2 0"} { return 0 }

  return 1
}

proc is_gf_hearts_minor_two_suiter {hand} {
  if {![two_suiter $hand]} { return 0 }

  set hs [hearts $hand]
  set cs [clubs $hand]
  set ds [diamonds $hand]
  if { $hs < 5 || ($cs < 5 && $ds < 5)} { return 0 }

  set points [hcp $hand]
  if {$points<7} { return 0 }

  set handshape [$hand pattern]
  if {$points<9 && $handshape != "6 5 1 1" && $handshape != "6 5 2 0"} { return 0 }

  return 1
}

proc is_minors_2n_preempt {hand} {
  set points [hcp $hand]
  if {$points<6 || $points>11 } { return 0 }

  set handshape [$hand pattern]
  if {$handshape != "6 5 1 1" && $handshape != "6 5 2 0" &&
      $handshape != "5 5 3 0" && $handshape != "5 5 2 1"} { return 0 }

  if {[clubs $hand]>=5 && [diamonds $hand]>=5} { return 1 }
  return 0
}

proc is_3cd_opener_1st2nd {hand} {
  if {[hcp $hand]>11 } { return 0 }
  if {[has_side_major $hand]} { return 0 }
  if {[controls $hand]>4} { return 0 }

  if {[is_tricky_suit $hand clubs] || ([is_tricky_suit $hand diamonds])} {return 1}

  return 0
}

proc is_standard_3cd_7carder {hand} {
    if {[hcp $hand]>11 } { return 0 }
    if {[has_side_major $hand]} { return 0 }
    if {[controls $hand]>3} { return 0 }
    set cs [clubs $hand]
    set ds [diamonds $hand]
    if {($cs==7 && [Honors $hand clubs]<=2 && $ds<4) ||
        ($ds==7 && [Honors $hand diamonds]<=2) && $cs<4} { return 1 }
    return 0
}

proc side_ace {hand suit} {
    # without king
    if {[Ace $hand $suit]==1 && [AceKing $hand $suit]==1} { return 1 }
    return 0
}

proc is_3n_opener {hand} {
  set points [hcp $hand]
  if { $points < 8 || $points > 14 } { return 0 }

  set cp [controls $hand]
  # AK, AK should probably start with 1C, KQJxxxxxx AK... maybe ok
  if { $cp > 5 } { return 0 }

  if { [$hand pattern] == "7 2 2 2" } { return 0 }

  if {[long_semi_solid $hand spades] && (
      ([AceKing $hand spades]==1 && ([side_ace $hand hearts] || [side_ace $hand diamonds] || [side_ace $hand clubs])) ||
      ([AceKing $hand spades]==2)
     )} { return 1 }

  if {[long_semi_solid $hand hearts] && (
      ([AceKing $hand hearts]==1 && ([side_ace $hand spades] || [side_ace $hand diamonds] || [side_ace $hand clubs])) ||
      ([AceKing $hand hearts]==2)
     )} { return 1 }

  return 0
}

proc is_shapely_minor_preempt {hand} {
  if { [hcp $hand] > 10 } { return 0 }
  if {[has_side_major $hand]} { return 0 }
  if {[controls $hand]>4} { return 0 }

  set ss [spades $hand]
  set hs [hearts $hand]
  set ds [diamonds $hand]
  set cs [clubs $hand]
  if {$cs >= 7 && ($ss <= 1 || $hs <= 1 || $ds <= 1)} { return 1}
  if {$ds >= 7 && ($ss <= 1 || $hs <= 1 || $cs <= 1)} { return 1}
  return 0
}

proc is_likely_3major_preempt {hand} {
  if { [hcp $hand] > 10 } { return 0 }

  set ss [spades $hand]
  set hs [hearts $hand]
  if {($ss >= 7 && $hs < 4) || ($hs >= 7 && $ss <4)} {return 1}
  return 0
}

proc any_offensive_suit {hand offense_tricks} {
  if { [offense $hand clubs] >= $offense_tricks ||
       [offense $hand diamonds] >= $offense_tricks ||
       [offense $hand hearts] >= $offense_tricks ||
       [offense $hand spades] >= $offense_tricks} { return 1 }
  return 0

}

proc is_likely_4level_preempt {hand} {
  if { [hcp $hand] > 12 } { return 0 }
  if { [$hand pattern] == "7 2 2 2" } { return 0 }
  if { [any_offensive_suit $hand 7] } { return 1 } else { return 0 }
}

proc is_insane_offensive_preempt {hand} {
    if { [hcp $hand] > 13 } { return 0 }
    if { [any_offensive_suit $hand 8] || [any_offensive_suit $hand 9] } { return 1 } else { return 0 }
}

proc is_8_plus_tricks {hand} {
    if { [hcp $hand] < 14 } { return 0 }
    if {[losers $hand]<= 5} { return 1 }
    return 0
}

proc is_powerhouse {hand maxlosers} {
  if {[losers $hand]<= $maxlosers} { return 1 }
  return 0
}

proc is_potential_4n_opener {hand} {
  if {[losers $hand]<= 3} { return 1 }
  return 0
}

proc both_minors {hand} {
  set cs [clubs $hand]
  set ds [diamonds $hand]
  if {($cs + $ds >= 9) && $cs >= 4 && $ds >= 4} { return 1 }
  return 0
}

proc singleton_or_void_major {hand} {
  if {[spades $hand]<=1 || [hearts $hand]<=1} { return 1 }
  return 0
}

proc any_singleton_or_void {hand} {
  if {[spades $hand]<=1 || [hearts $hand]<=1 || [diamonds $hand]<=1 || [clubs $hand]<=1} { return 1 }
  return 0
}

# Selection of artificial 1C opening responses
proc is_1n_marmic_swedish_club_resp {hand} {
  set points [hcp $hand]
  if { [is_marmic $hand] && $points >= 12 } { return 1 }
  return 0
}

proc is_1n_unbal_minor_swedish_club_resp {hand} {
  if { [hcp $hand] < 12 } { return 0 }
  if { [has_side_major $hand] || [is_2s_swedish_club_resp $hand] ||
       [balanced $hand] } { return 0 }
  return 1
}

proc is_old_1n_bal_swedish_club_response {hand} {
  if { [hcp $hand] < 12 } { return 0 }
  if { [balanced $hand] } { return 1 }
  return 0
}

proc is_any_1n_swedish_club_response {hand} {
  return [expr {[is_old_1n_bal_swedish_club_response $hand] ||
                [is_1n_unbal_minor_swedish_club_resp $hand] ||
                [is_1n_marmic_swedish_club_resp $hand]}]
}

proc is_2cd_swedish_club_resp {hand} {
  set points [hcp $hand]
  if { ![has_side_major $hand] && ![flattish $hand] && $points >= 7 && $points <= 10 } { return 1 }
  return 0
}

proc is_2h_or_2n_swedish_club_resp {hand} {
  set points [hcp $hand]
  if { ![has_side_major $hand] && [flattish $hand] && $points >= 9 && $points <= 12 } { return 1 }
  return 0
}

proc is_2s_swedish_club_resp {hand} {
  set points [hcp $hand]
  if { [both_minors $hand] && [singleton_or_void_major $hand] && $points >= 12 && $points <= 15} { return 1 }
  return 0
}

proc AKQJ {hand suit} {
  return [expr [Top4 $hand $suit]==4]
}

proc eq_3_control_points_and_max_12_hcp {hand} {
  if {[controls $hand]!=3} { return 0 }
  if {[hcp $hand]>12} { return 0 }
  return 1
}

proc is_3n_swedish_club_resp {hand} {
  # no outside A/K and a side Q at best
  if {![eq_3_control_points_and_max_12_hcp $hand]} { return 0 }
  # totally solid 6 carder
  if {[AKQJ $hand spades] && [spades $hand]==6 ||
      [AKQJ $hand hearts] && [hearts $hand]==6 ||
      [AKQJ $hand diamonds] && [diamonds $hand]==6 ||
      [AKQJ $hand clubs] && [clubs $hand]==6} { return 1 }
  return 0
}

defvector AQJ 1 0 1 1
defvector KQJ 0 1 1 1
proc is_4cd_swedish_club_response {hand} {
  # no outside A/K and a side Q at best
  if {![hcp $hand]>10} { return 0 }

  # 8 carder missing A/K otherwise solid
  if {[Top4 $hand spades]!=4 &&
      ([AQJ $hand spades]==3 || [KQJ $hand spades]==3) &&
      [spades $hand]==8 &&
      [Top2 $hand hearts]==0 && [Top2 $hand diamonds]==0 && [Top2 $hand clubs]==0
  } { return 1 }
  if {[Top4 $hand hearts]!=4 &&
      ([AQJ $hand hearts]==3 || [KQJ $hand hearts]==3) &&
      [hearts $hand]==8 &&
      [Top2 $hand spades]==0 && [Top2 $hand diamonds]==0 && [Top2 $hand clubs]==0
  } { return 1 }
  return 0
}

proc is_4hs_swedish_club_response {hand} {
  # no outside A/K and a side Q at best
  if {![eq_3_control_points_and_max_12_hcp $hand]} { return 0 }
  # totally solid 7 carder
  if {[AKQJ $hand spades] && [spades $hand]==7 ||
      [AKQJ $hand hearts] && [hearts $hand]==7} { return 1 }
  return 0
}

proc is_3x_preempt_swedish_club_response {hand} {
  if { [hcp $hand] > 7 } { return 0 }

  if {[is_shapely_minor_preempt $hand] ||
      [is_standard_3cd_7carder $hand] ||
      [is_likely_3major_preempt $hand] ||
      [is_likely_4level_preempt $hand]} { return 1 }

  return 0
}

proc is_possible_inverted_diamond_raise {hand} {
    if { [hcp $hand] < 10 } { return 0 }
    if { [has_side_major $hand] } { return 0 }
    set ds [diamonds $hand]
    if { $ds <4 } { return 0 }
    return 1
}

proc is_possible_wjs_1d_response {hand} {
    if { [hcp $hand] >= 10 } { return 0 }
    set cs [clubs $hand]
    set hs [hearts $hand]
    set ss [spades $hand]
    if { $hs >=6 || $ss >= 6 || $cs >= 6 } { return 1 }
    return 0
}

proc is_possible_splinter_1d_response {hand} {
    if { [hcp $hand] < 13 } { return 0 }
    set ds [diamonds $hand]
    set cs [clubs $hand]
    set hs [hearts $hand]
    set ss [spades $hand]
    if { $ds >=6 && ($cs == 1 || $hs == 1 || $ss == 1) } { return 1 }
    return 0
}

proc is_possible_diamond_preempt_1d_response {hand} {
  if { [hcp $hand] > 10 } { return 0 }
  set ds [diamonds $hand]
  if { $ds >= 6 } { return 1 }
  return 0
}

proc north_south_may_overcall_1N {top_nt_range} {
  # assuming east opens
  set s_hcp [hcp south]
  if {[flattish south] && [flattish north] && ($s_hcp < $top_nt_range) && ([hcp north] < $top_nt_range) } { return 0 }

  set EW_GameGoing [expr ([hcp east] + [hcp west] >= 24)]
  if {([flattish south] || $s_hcp < 8) && $EW_GameGoing} { return 0 }
  return 1
}

proc south_may_overcall_opponents_1N_with_north_invitational {top_nt_range} {
  set s_hcp [hcp south]

  # ignore penalty double or flattish hands for south
  if {[flattish south] || ($s_hcp >= $top_nt_range)} { return 0 }

  if {[hcp east] + [hcp west] >= 18} { return 0 }
  if {$s_hcp < 9} { return 0 }

  set n_hcp [hcp north]
  if {$n_hcp < 9 || $n_hcp > 13} { return 0 }

  return 1
}

proc opens_std_1minor_prepared {hand} {
  set points [hcp $hand]
  if { $points < 11 || $points > 21 } { return 0 }

  set cs [clubs $hand]
  set ds [diamonds $hand]
  set hs [hearts $hand]
  set ss [spades $hand]

  if {[5CM_nt $hand 15 17]} { return 0 }
  if {[flattish $hand] && $points >= 20 } { return 0 }

  if {($cs > $hs && $cs > $ss) || ($ds > $hs && $ds > $ss)} {return 1}
  if { $hs >= 5 || $ss >= 5} {return 0}

  return 1
}

proc has_both_majors_michaels {hand} {
  set points [hcp $hand]
  if {$points < 5 || $points > 15} { return 0 }

  set hs [hearts $hand]
  set ss [spades $hand]
  if { $hs < 5 || $ss < 5 } { return 0 }

  return 1
}

proc is_weak_2DH {hand} {
  set points [hcp $hand]
  if {$points < 5 || $points > 11 } { return 0 }

  if { [hearts $hand] >= 6 || [diamonds $hand] >= 6 } { return 1 }

  return 0
}
