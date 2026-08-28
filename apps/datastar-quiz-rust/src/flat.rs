//! A group-of-slices container with two allocations instead of one per group.
//!
//! An auction is a list of POSITIONS and a position is a list of the calls it allows -- one for an
//! ordinary call, several for `2D/2H`. Written the obvious way that is a `Vec<Vec<Bid>>`, and the
//! inner `Vec` is where the allocation goes: the swedish system prepares to about 380,000 positions
//! and almost every one of them holds exactly one call, so the obvious shape spends 380,000 heap
//! allocations and 24 bytes of pointer on each 6-byte payload.
//!
//! This stores the calls end to end and remembers where each group stops, which is two allocations
//! per auction -- and, once the corpus packs its auctions into one of these, two for the lot. The
//! matcher then walks contiguous memory.

use std::fmt::Debug;

/// Groups of `T`, stored flat.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct Flat<T> {
    items: Vec<T>,
    /// exclusive end offset of each group
    ends: Vec<u32>,
}

impl<T> Flat<T> {
    pub fn new() -> Self {
        Flat {
            items: Vec::new(),
            ends: Vec::new(),
        }
    }

    pub fn with_capacity(groups: usize, items: usize) -> Self {
        Flat {
            items: Vec::with_capacity(items),
            ends: Vec::with_capacity(groups),
        }
    }

    /// How many groups.
    pub fn len(&self) -> usize {
        self.ends.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ends.is_empty()
    }

    /// How many items across every group.
    pub fn item_count(&self) -> usize {
        self.items.len()
    }

    pub fn push_group(&mut self, group: impl IntoIterator<Item = T>) {
        self.items.extend(group);
        self.ends.push(self.items.len() as u32);
    }

    /// Start a group that is then filled with [`push_item`](Self::push_item) and closed with
    /// [`close_group`](Self::close_group). For the cases where the group's contents are produced by
    /// a loop that can also produce nothing.
    pub fn push_item(&mut self, item: T) {
        self.items.push(item);
    }

    /// Close the group opened by the last [`close_group`](Self::close_group) or by construction.
    pub fn close_group(&mut self) {
        self.ends.push(self.items.len() as u32);
    }

    /// How many items are in the group currently being built.
    pub fn open_len(&self) -> usize {
        self.items.len() - self.ends.last().copied().unwrap_or(0) as usize
    }

    #[inline]
    pub fn group(&self, index: usize) -> &[T] {
        let end = self.ends[index] as usize;
        let start = if index == 0 {
            0
        } else {
            self.ends[index - 1] as usize
        };
        &self.items[start..end]
    }

    pub fn groups(&self) -> impl Iterator<Item = &[T]> {
        (0..self.len()).map(|index| self.group(index))
    }

    pub fn clear(&mut self) {
        self.items.clear();
        self.ends.clear();
    }
}

impl<T> Flat<T> {
    /// A borrowed view of every group. See [`Groups`].
    pub fn view(&self) -> Groups<'_, T> {
        Groups {
            items: &self.items,
            ends: &self.ends,
            base: 0,
        }
    }
}

/// A borrowed run of groups: the shape both a standalone [`Flat`] and one packed into a bigger
/// arena can produce.
///
/// `base` is what makes the second case work. The corpus stores every prepared auction's calls in
/// ONE `Vec<Bid>` and every position's end offset in ONE `Vec<u32>`, so a single auction is a slice
/// of the ends whose offsets are absolute into the shared items. Carrying the run's starting offset
/// alongside is cheaper than rebasing, and means a view costs three words and no allocation at all.
pub struct Groups<'a, T> {
    pub items: &'a [T],
    pub ends: &'a [u32],
    pub base: u32,
}

// Written out rather than derived: `#[derive(Copy)]` would add a `T: Copy` bound, and a view is
// three shared references' worth of data whatever it points at.
impl<T> Clone for Groups<'_, T> {
    fn clone(&self) -> Self {
        *self
    }
}
impl<T> Copy for Groups<'_, T> {}

impl<'a, T> Groups<'a, T> {
    /// Build a view over a run of a shared arena.
    pub fn new(items: &'a [T], ends: &'a [u32], base: u32) -> Groups<'a, T> {
        Groups { items, ends, base }
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.ends.len()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.ends.is_empty()
    }

    #[inline]
    pub fn group(&self, index: usize) -> &'a [T] {
        let end = self.ends[index] as usize;
        let start = if index == 0 {
            self.base as usize
        } else {
            self.ends[index - 1] as usize
        };
        &self.items[start..end]
    }

    pub fn groups(&self) -> impl Iterator<Item = &'a [T]> + use<'a, T> {
        let copy = *self;
        (0..copy.len()).map(move |index| copy.group(index))
    }
}

impl<T: Debug> Debug for Groups<'_, T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_list().entries(self.groups()).finish()
    }
}

impl<T: Clone> Flat<T> {
    /// Append every group of `other`.
    pub fn extend_from(&mut self, other: &Flat<T>) {
        for group in other.groups() {
            self.push_group(group.iter().cloned());
        }
    }

    /// Append the first `count` groups of `other`.
    pub fn extend_prefix(&mut self, other: &Flat<T>, count: usize) {
        for index in 0..count.min(other.len()) {
            self.push_group(other.group(index).iter().cloned());
        }
    }
}

impl<T: Debug> Debug for Flat<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_list().entries(self.groups()).finish()
    }
}

impl<T> FromIterator<Vec<T>> for Flat<T> {
    fn from_iter<I: IntoIterator<Item = Vec<T>>>(iter: I) -> Self {
        let mut flat = Flat::new();
        for group in iter {
            flat.push_group(group);
        }
        flat
    }
}
