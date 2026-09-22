use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

// Bound Rust parser allocations, including allocations made by dependencies.
struct BoundedAllocator;
static ALLOCATED: AtomicUsize = AtomicUsize::new(0);
#[global_allocator]
static ALLOCATOR: BoundedAllocator = BoundedAllocator;

unsafe impl GlobalAlloc for BoundedAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if ALLOCATED.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |used| {
            used.checked_add(layout.size()).filter(|&size| size <= crate::HEAP_LIMIT)
        }).is_err() { return std::ptr::null_mut(); }
        // SAFETY: The layout is passed unchanged to the system allocator.
        let pointer = unsafe { System.alloc(layout) };
        if pointer.is_null() { ALLOCATED.fetch_sub(layout.size(), Ordering::Relaxed); }
        pointer
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        // SAFETY: GlobalAlloc callers supply the original pointer and layout.
        unsafe { System.dealloc(pointer, layout) };
        ALLOCATED.fetch_sub(layout.size(), Ordering::Relaxed);
    }
}
