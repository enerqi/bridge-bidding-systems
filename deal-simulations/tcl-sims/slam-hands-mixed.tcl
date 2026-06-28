# Run with: deal.exe [-v] -i path/to/scratch.tcl n
# The TCL interpreter annoyingly needs forward slashes in windows paths
# The main `deal.exe` program expects to run with the working directory matching the deal.exe directory
# http://bridge.thomasoandrews.com/deal30/
set script_path [ file dirname [ file normalize [ info script ] ] ]
source $script_path/deal-utils.tcl

main {

  set combined_hcp [expr {[hcp north] + [hcp south]}]
  set random_bucket [expr {int(rand() * 3) + 1}]
  set require_shortage [expr {int(rand() * 2)}]
  
  set has_shortage [expr {[any_singleton_or_void north] || [any_singleton_or_void south]}]
  
  # Check shortage requirement
  if {$require_shortage == 1 && !$has_shortage} { reject }
  if {$require_shortage == 0 && $has_shortage} { reject }

  if {$random_bucket == 1} {
    # Bucket 1: 30+ hcp
    if {$combined_hcp >= 30} { accept }
  } elseif {$random_bucket == 2} {
    # Bucket 2: 32+ hcp
    if {$combined_hcp >= 32} { accept }
  } else {
    # Bucket 3: 35+ hcp
    if {$combined_hcp >= 35} { accept }
  }

  reject
}
