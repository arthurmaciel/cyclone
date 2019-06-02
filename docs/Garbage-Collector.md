[<img src="images/cyclone-logo-04-header.png" alt="cyclone-scheme">](http://github.com/justinethier/cyclone)

# Garbage Collector

- [Introduction](#introduction)
- [Terms](#terms)
- [Code](#code)
- [Data Structures](#data-structures)
  - [Heap](#heap)
  - [Thread Data](#thread-data)
  - [Object Header](#object-header)
  - [Mark Buffers](#mark-buffers)
- [Minor Collection](#minor-collection)
- [Major Collection](#major-collection)
  - [Tri-color Marking](#tri-color-marking)
  - [Handshakes](#handshakes)
  - [Collection Cycle](#collection-cycle)
  - [Mutator Functions](#mutator-functions)
  - [Collector Functions](#collector-functions)
  - [Cooperation by the Collector](#cooperation-by-the-collector)
  - [Running the Collector](#running-the-collector)
- [Looking Ahead](#looking-ahead)
- [Further Reading](#further-reading)

# Introduction

The goal of this paper is to provide a high-level overview of Cyclone's garbage collector. The explanation is fairly technical; there are some introductory articles on garbage collection in the [further reading section](#further-reading) that may provide more familiarity with the concepts and that are worthwhile to read in their own right.

The collector has the following requirements:

- Efficiently free allocated memory.
- Allow the language implementation to support tail calls and continuations.
- Allow the language to support native multithreading.

Cyclone uses generational garbage collection (GC) to automatically free allocated memory using two types of collection. In practice, most allocations consist of short-lived objects such as temporary variables. Minor GC is done frequently to clean up most of these short-lived objects. Some objects will survive this collection because they are still referenced in memory. A major collection runs less often to free longer-lived objects that are no longer being used by the application.

Cheney on the MTA, a technique introduced by Henry Baker, is used to implement the first generation of our garbage collector. Objects are allocated directly on the stack using `alloca` so allocations are very fast, do not cause fragmentation, and do not require a special pass to free unused objects. Baker's technique uses a copying collector for both the minor and major generations of collection. One of the drawbacks of using a copying collector for major GC is that it relocates all the live objects during collection. This is problematic for supporting native threads because an object can be relocated at any time, invalidating any references to the object. To prevent this either all threads must be stopped while major GC is running or a read barrier must be used each time an object is accessed. Both options add a potentially significant overhead so instead another type of collector is used for the second generation.

Cyclone supports native threads by using a tracing collector based on the Doligez-Leroy-Gonthier (DLG) algorithm for major collections. An advantage of this approach is that objects are not relocated once they are placed on the heap. In addition, major GC executes asynchronously so threads can continue to run concurrently even during collections.

# Terms
- Collector - A thread running the garbage collection code. The collector is responsible for coordinating and performing most of the work for major garbage collections.
- Continuation - With respect to the collectors, this is a function that is called to resume execution of application code. For more information see [this article on continuation passing style](https://en.wikipedia.org/wiki/Continuation-passing_style).
- Forwarding Pointer - When a copying collector relocates an object it leaves one of these pointers behind with the object's new address.
- Garbage Collector (GC) - A form of automatic memory management that frees memory allocated by objects that are no longer used by the program.
- Heap - A section of memory used to store longer-lived variables. In C, heap memory is allocated using built-in functions such as `malloc`, and memory must be explicitly deallocated using `free`.
- Mutation - A modification to an object. For example, changing a vector (array) entry.
- Mutator - A thread running user (or "application") code; there may be more than one mutator running concurrently.
- Read Barrier - Code that is executed before reading an object. Read barriers have a larger overhead than write barriers because object reads are much more common.
- Root - During tracing the collector uses these objects as the starting point to find all reachable data.
- Stack - The C call stack, where local variables are allocated and freed automatically when a function returns. Stack variables only exist until the function that created them returns, at which point the memory may be overwritten. The stack has a very limited size and undefined behavior (usually a crash) will result if that size is exceeded.
- Write Barrier - Code that is executed before writing to an object.

# Code

The implementation code is available here:

- [`runtime.c`](../runtime.c) contains most of the runtime system, including code to perform minor GC. A good place to start would be the `GC` and `gc_minor` functions.
- [`gc.c`](../gc.c) contains the major GC code.

# Data Structures

## Heap

The heap is used to store all objects that survive minor GC, and consists of a linked list of pages. Each page contains a contiguous block of memory and a linked list of free chunks. When a new chunk is requested the first free chunk large enough to meet the request is found and either returned directly or carved up into a smaller chunk to return to the caller.

Memory is always allocated in multiples of 32 bytes. On the one hand this helps prevent external fragmentation by allocating many objects of the same size. But on the other it incurs internal fragmentation because an object will not always fill all of its allocated memory.

The heap is locked during allocation and sweep operations to protect against concurrent access.

If there is not enough free memory to fulfill a request a new page is allocated and added to the heap. This is the only choice, unfortunately. The collection process is asynchronous so memory cannot be freed immediately to make room.

## Thread Data

At runtime Cyclone passes the current continuation, number of arguments, and a thread data parameter to each compiled C function. The continuation and arguments are used by the application code to call into its next function with a result. Thread data is a structure that contains all of the necessary information to perform collections, including:

- Thread state
- Stack boundaries
- Jump buffer
- List of mutated objects detected by the minor GC write barrier
- Major GC parameters - mark buffer, last read/write, etc (see next sections)
- Call history buffer
- Exception handler stack

Each thread has its own instance of the thread data structure and its own stack (assigned by the C runtime/compiler).

## Object Header

Each object contains a header with the following information:

- Tag - A number indicating the object type: cons, vector, string, etc.
- Mark - The status of the object's memory.
- Grayed - A field indicating the object has been grayed but has not been added to a mark buffer yet (see major GC sections below). This is only applicable for objects on the stack.

## Mark Buffers

Mark buffers are used to hold gray objects instead of explicitly marking objects gray. These mark buffers consist of fixed-size pointer arrays that are increased in size as necessary using `realloc`.  Each mutator has a reference to a mark buffer holding their gray objects. A last write variable is used to keep track of the buffer size.

The collector updates the mutator's last read variable each time it marks an object from the mark buffer. Marking is finished when last read and last write are equal. The collector also maintains a single mark stack of objects that the collector has marked gray.

An object on the stack cannot be added to a mark buffer because the reference may become invalid before it can be processed by the collector.

# Minor Collection

Cyclone converts the original program to continuation passing style (CPS) and compiles it as a series of C functions that never return. At runtime each mutator periodically checks to see if its stack has exceeded a certain size. When this happens a minor GC is started and all live stack objects are copied to the heap.

Root objects are live objects the collector uses to begin the tracing process. Cyclone's minor collector treats the following as roots:

- The current continuation
- Arguments to the current continuation
- Mutations contained in the write barrier
- Closures from the exception stack
- Global variables

A minor collection is always performed for a single mutator thread, usually by the thread itself. The algorithm is based on Cheney on the MTA:

- Move any root objects on the stack to the heap. For each object moved: 
  - Replace the stack object with a forwarding pointer. The forwarding pointer ensures all references to a stack object refer to the same heap object, and allows minor GC to handle cycles.
  - Record each moved object in a buffer to serve as the Cheney to-space.
- Loop over the to-space buffer and check each object moved to the heap. Move any child objects that are still on the stack. This loop continues until all live objects are moved.
- Cooperate with the collection thread (see next section).
- Perform a `longjmp` to reset the stack and call into the current continuation.

Any objects left on the stack after `longjmp` are considered garbage. There is no need to clean them up because the stack will just re-use the memory as it grows.

Finally, although not mentioned in Baker's paper, a heap object can be modified to contain a reference to a stack object. For example, by using a `set-car!` to change the head of a list. This is problematic since stack references are no longer valid after a minor GC, and the GC does not check heap objects. We account for these mutations by using a write barrier to maintain a list of each modified object. During GC, these modified objects are treated as roots to avoid dangling references.

# Major Collection

A single heap is used to store objects relocated from the various thread stacks. Eventually the heap will run too low on space and a collection is required to reclaim unused memory. The collector thread is used to perform a major GC with cooperation from the mutator threads.

## Tri-color Marking

An object can be marked using any of the following colors to indicate the status of its memory:

  - Blue - Unallocated memory.
  - Red - An object on the stack.
  - White - Heap memory that has not been scanned by the collector. 
  - Gray - Objects marked by the collector that may still have child objects that must be marked.
  - Black - Objects marked by the collector whose immediate child objects have also been marked.

Only objects marked as white, gray, or black participate in major collections:

- White objects are freed during the sweep state. White is sometimes also referred to as the clear color.
- Gray is never explicitly assigned to an object. Instead, objects are grayed by being added to lists of gray objects awaiting marking. This improves performance by avoiding repeated passes over the heap to search for gray objects.
- Black objects survive the collection cycle. Black is sometimes referred to as the mark color as live objects are ultimately marked black.

## Handshakes

Instead of stopping the world and pausing all threads, when the collector needs to coordinate with the mutators it performs a handshake.

Each of the mutator threads, and the collector itself, has a status variable:

     typedef enum { STATUS_ASYNC 
                  , STATUS_SYNC1 
                  , STATUS_SYNC2 
                  } gc_status_type;

The collector will update its status variable and then wait for all of the collectors to change their status before continuing. The mutators periodically call a cooperate function to check in and update their status to match the collectors. A handshake is complete once all mutators have updated their status.

## Collection Cycle

During a GC cycle the collector thread transitions through the following states.

### Clear
The collector swaps the values of the clear color (white) and the mark color (black). This is more efficient than modifying the color on each object in the heap. The collector then transitions to sync 1. At this point no heap objects are marked, as demonstrated below:

<img src="images/gc-graph-clear.png" alt="Initial object graph">

### Mark
The collector transitions to sync 2 and then async. At this point it marks the global variables and waits for the mutators to also transition to async. When a mutator transitions it will mark its roots and use black as the allocation color to prevent any new objects from being collected during this cycle:

<img src="images/gc-graph-mark.png" alt="Initial object graph">

### Trace
The collector finds all live objects using a breadth-first search and marks them black:

<img src="images/gc-graph-trace.png" alt="Initial object graph">

### Sweep
The collector scans the heap and frees memory used by all white objects:

<img src="images/gc-graph-sweep.png" alt="Initial object graph">

If the heap is still low on memory at this point the heap will be increased in size. Also, to ensure a complete collection, data for any terminated threads is not freed until now.

### Resting
The collector cycle is complete and it rests until it is triggered again.

## Mutator Functions

Each mutator calls the following functions to coordinate with the collector.

### Create

This function is called by a mutator to allocate memory on the heap for an object. This is generally only done during a minor GC when each object is relocated to the heap.

### Update

A write barrier is used to ensure any modified objects are properly marked for the current collection cycle. There are two cases:

- Gray the object's new and old values if the mutator is in a synchronous status. 
- Gray the object's old value if the collector is in the tracing stage.

Because updates can occur at any time a modified object may still live on the stack. In this case the object is tagged to be grayed when it is relocated to the heap.

### Cooperate

Each mutator is required to periodically call this function to cooperate with the collector. During cooperation a mutator will update its status to match the collector's status, to handshake with the collector. 

In addition when a mutator transitions to async it will:

- Mark all of its roots gray
- Use black as the allocation color for any new objects to prevent them from being collected during this cycle.

Cyclone's mutators cooperate after each minor GC, for two reasons. Minor GC's are frequent and immediately afterwards all of the mutator's live objects can be marked because they are on the heap.

### Mark Gray

Mutators call this function to add an object to their mark buffer.

    mark_gray(m, obj):
      if obj != clear_color:
        m->mark_buffer[m->last_write] = obj
        m->last_write++

## Collector Functions

### Collector Mark Gray

The collector calls this function to add an object to the mark stack.

    collector_mark_gray(obj):
      if obj != clear_color:
        mark_stack->push(obj)

### Mark Black

The collector calls this function to mark an object black and mark all of the object's children gray using Collector Mark Gray.

    mark_black(obj):
      if mark(obj) != mark_color:
        for each child(c):
          collector_mark_gray(c)
        mark(obj) = mark_color


### Empty Collector Mark Stack

This function removes and marks each object on the collector's mark stack.

    empty_collector_mark_stack():
      while not mark_stack->empty():
        mark_black(mark_stack->pop())

### Collector Trace

This function performs tracing for the collector by looping over all of the mutator mark buffers. All of the remaining objects in each buffer are marked black, as well as all the remaining objects on the collector's mark stack. This function continues looping until there are no more objects to mark:

    collector_trace():
      clean = 0
      while not clean:
        clean = 1
        for each mutator(m):
          while m->last_read < m->last_write:
            clean = 0
            mark_black(m->mark_buffer[m->last_read])
            empty_collector_mark_stack()
            m->last_read++

## Cooperation by the Collector

In practice a mutator will not always be able to cooperate in a timely manner. For example, a thread can block indefinitely waiting for user input or reading from a network port. In the meantime the collector will never be able to complete a handshake with this mutator and major GC will never be performed.

Cyclone solves this problem by requiring that a mutator keep track of its thread state. With this information the collector can cooperate on behalf of a blocked mutator and do the work itself instead of waiting for the mutator. 

The possible thread states are:

- `CYC_THREAD_STATE_NEW` - A new thread not yet running.
- `CYC_THREAD_STATE_RUNNABLE` - A thread that can be scheduled to run by the OS.
- `CYC_THREAD_STATE_BLOCKED` - A thread that could be blocked.
- `CYC_THREAD_STATE_BLOCKED_COOPERATING` - A blocked thread that the collector is cooperating with on behalf of the mutator.
- `CYC_THREAD_STATE_TERMINATED` - A thread that has been terminated by the application but its resources have not been freed up yet.

Before entering a C function that could block the mutator must call a function to update its thread state to `CYC_THREAD_STATE_BLOCKED`. This indicates to the collector that the thread may be blocked.

When the collector handshakes it will check each mutator to see if it is blocked. Normally in this case the collector can just update the blocked mutator's status and move on to the next one. But if the mutator is transitioning to async all of its objects need to be relocated from the stack so they can be marked. In this case the collector changes the thread's state to `CYC_THREAD_STATE_BLOCKED_COOPERATING`, locks the mutator's mutex, and performs a minor collection for the thread. The mutator's objects can then be marked gray and its allocation color can be flipped. When it is finished cooperating for the mutator the collector releases its mutex.

When a mutator exits a (potentially) blocking section of code, it must call another function to update its thread state to `CYC_THREAD_STATE_RUNNABLE`. In addition, the function will detect if the collector cooperated for this mutator by checking if its status is `CYC_THREAD_STATE_BLOCKED_COOPERATING`. If so, the mutator waits for its mutex to be released to ensure the collector has finished cooperating. The mutator then performs a minor GC again to ensure any additional objects - such as results from the blocking code - are moved to the heap before calling `longjmp` to jump back to the beginning of its stack. Either way, the mutator now calls into its continuation and resumes normal operations.

## Running the Collector

Cyclone checks the amount of free memory as part of its cooperation code. A major GC cycle is started if the amount of free memory dips below a threshold. The goal is to run major collections infrequently, but at the same time we want to prevent unnecessary allocations.

# Looking Ahead

The garbage collector is by far the most complex component of Cyclone. The primary motivations in developing it were to:

- Extend baker's approach to support multiple mutators
- Position to potentially support state of the art GC's built on top of DLG (Stopless, Chicken, Clover)

There are a few limitations or potential issues with the current implementation:

- Heap memory fragmentation has not been addressed and could be an issue for long-running programs. Traditionally a compaction process is used to defragment a heap. An alternative strategy has also been suggested by Pizlo:

    > instead of copying objects to evacuate fragmented regions of the heap, fragmentation is instead embraced. A fragmented heap is allowed to stay fragmented, but the collector ensures that it can still satisfy allocation requests even if no large enough contiguous free region of space exists.

- Accordingly, the runtime needs to be able to handle large objects that could potentially span one or more pages.
- There is probably too much heap locking going on, and this could be an issue for a large heap and/or a large number of mutators. Improvements can likely be made in this area.

Cyclone needs to be tested with large heap and large allocations. I believe it should work well for large heaps that do not allocate too many objects of irregular size. However, a program regularly allocating large strings or vectors could cause significant heap fragmentation over time.

Ultimately, a garbage collector is tricky to implement and the focus must primarily be on correctness first, with an eye towards performance.

# Further Reading

- [Baby's First Garbage Collector](http://journal.stuffwithstuff.com/2013/12/08/babys-first-garbage-collector/), by Bob Nystrom
- [Chibi-Scheme](https://github.com/ashinn/chibi-scheme)
- [CHICKEN internals: the garbage collector](http://www.more-magic.net/posts/internals-gc.html), by Peter Bex
- [CONS Should Not CONS Its Arguments, Part II: Cheney on the M.T.A.](https://github.com/justinethier/cyclone/raw/master/docs/research-papers/CheneyMTA.pdf), by Henry Baker
- Fragmentation Tolerant Real Time Garbage Collection (PhD Dissertation), by Filip Pizlo
- [The Garbage Collection Handbook: The Art of Automatic Memory Management](http://gchandbook.org/), by Antony Hosking, Eliot Moss, and Richard Jones
- Implementing an on-the-fly garbage collector for Java, by Domani et al
- Incremental Parallel Garbage Collection, by Paul Thomas
- Portable, Unobtrusive Garbage Collection for Multiprocessor Systems, by Damien Doligez and Georges Gonthier
