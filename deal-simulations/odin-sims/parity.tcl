# parity.tcl — Tcl side of the parity check. One verdict digit per deal, always reject so deal.exe
# reads the whole file. Mirrors the OR of a representative sample of scenario .tcl bodies.
source C:/Users/Enerqi/docs/bridge/bridge-bidding-system/deal-simulations/tcl-sims/deal-utils.tcl

# 1d-weak-minor-minors.tcl
proc s_weakmm {} {
  if {[is_1d_opener north] && [hcp south]<10 && [hcp south]>4 && ![has_side_major south] && ![flattish south] && ([hcp east]<8 || ([hearts east]<5 && [spades east]<5))} { return 1 }
  return 0
}

# 1major-minisplinter-or-single-suit-invite.tcl
proc s_minisplinter {} {
  if {[is_1major_opener north] &&
      (([hcp south]>=7 && [hcp south]<=11 && [has_major_support north south 4] && [any_singleton_or_void south])
      ||
      ([hcp south]>=9 && [hcp south]<=12 && [any_good_6_plus_carder south]))} { return 1 }
  return 0
}

# defence-vs-high-preempts.tcl
proc s_highpre {} {
  if {[is_minors_2n_preempt west] || [is_minors_2n_preempt east]} { return 1 }
  if {[is_shapely_minor_preempt west] || [is_shapely_minor_preempt east]} { return 1 }
  if {[is_standard_3cd_7carder west] || [is_standard_3cd_7carder east]} { return 1 }
  if {[is_likely_3major_preempt west] || [is_likely_3major_preempt east]} { return 1 }
  if {[is_likely_4level_preempt west] || [is_likely_4level_preempt east]} { return 1 }
  return 0
}

# defense-vs-all-preempts.tcl
proc s_allpre {} {
  if {[is_minors_2n_preempt west] || [is_minors_2n_preempt east]} { return 1 }
  if {[is_shapely_minor_preempt west] || [is_shapely_minor_preempt east]} { return 1 }
  if {[is_standard_3cd_7carder west] || [is_standard_3cd_7carder east]} { return 1 }
  if {[is_weak2_major west] || [is_weak2_major east]} { return 1 }
  if {[is_generic_5card_unbal_weak2 west] || [is_generic_5card_unbal_weak2 east]} { return 1 }
  if {[is_generic_weak2d west] || [is_generic_weak2d east]} { return 1 }
  if {[is_likely_3major_preempt west] || [is_likely_3major_preempt east]} { return 1 }
  if {[is_likely_4level_preempt west] || [is_likely_4level_preempt east]} { return 1 }
  return 0
}

# roman-2c-related.tcl
proc s_roman {} {
  if {![5CM_nt north 11 13] && ([is_2c_opener north] || [is_2d_intermediate_opener north] || [is_1d_opener north])} { return 1 }
  return 0
}

# acol-lessons-balanced.tcl
proc s_acol {} {
  if {[flattish north] && [flattish south] && [hcp north] >= 11 && [hcp south] >= 5} { return 1 }
  return 0
}

# 1minor-(1s).tcl
proc s_1minor1s {} {
  if {([is_1d_opener north] || [is_any_1c_opener north]) && [spades east]>=5 && [is_1major_overcall east] && [hcp south] >=5 } { return 1 }
  return 0
}

# 1d-then-1x-interference.tcl
proc s_interference {} {
  set hs [hearts south]
  set ss [spades south]
  set h_fit [expr {[hearts east] + [hearts west]}]
  set s_fit [expr {[spades east] + [spades west]}]
  if {($s_fit >= 8 || $h_fit >= 8) && [hcp south]>=6 && ($hs>3 || $ss>3) && [is_1d_opener north] && ([is_1major_overcall east] || [is_1d_takeout east])} { return 1 }
  return 0
}

main {
  set v [expr {[s_weakmm] || [s_minisplinter] || [s_highpre] || [s_allpre] ||
               [s_roman] || [s_acol] || [s_1minor1s] || [s_interference]}]
  puts $v
  reject
}
