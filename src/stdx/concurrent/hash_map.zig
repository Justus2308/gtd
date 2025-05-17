const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const default_bucket_count = 4;

pub fn StringHashMapUnmanaged(comptime V: type) type {
    return HashMapUnmanaged(
        []const u8,
        V,
        std.hash_map.StringContext,
        std.hash_map.default_max_load_percentage,
        default_bucket_count,
    );
}

pub fn AutoHashMapUnmanaged(
    comptime K: type,
    comptime V: type,
) type {
    return HashMapUnmanaged(
        K,
        V,
        std.hash_map.AutoContext(K),
        std.hash_map.default_max_load_percentage,
        default_bucket_count,
    );
}

pub fn HashMapUnmanaged(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime max_load_percentage: u64,
    comptime bucket_count: usize,
) type {
    return struct {
        buckets: [bucket_count]Bucket,

        const Self = @This();

        pub const empty = Self{
            .buckets = @splat(.empty),
        };

        pub fn get(self: Self, key: K) ?V {
            const hashed = hash(key);
            return self.getBucket(hashed).get(key, hashed);
        }
        pub fn getPtr(self: Self, key: K) ?*V {
            const hashed = hash(key);
            return self.getBucket(hashed).getPtr(key, hashed);
        }
        pub fn tryGetPtr(self: Self, key: K) ?*V {
            const hashed = hash(key);
            return self.getBucket(hashed).tryGetPtr(key, hashed);
        }

        pub fn put(
            self: *Self,
            allocator: Allocator,
            key: K,
            value: V,
        ) Allocator.Error!void {
            const hashed = hash(key);
            try self.getBucket(hashed).put(allocator, key, value, hashed);
        }

        pub fn putAndGetPtr(
            self: *Self,
            allocator: Allocator,
            key: K,
            value: V,
        ) Allocator.Error!*V {
            const hashed = hash(key);
            return self.getBucket(hashed).putAndGetPtr(allocator, key, value, hashed);
        }

        pub fn getPtrOrPutAndGetPtr(
            self: *Self,
            allocator: Allocator,
            key: K,
            value: V,
        ) Allocator.Error!*V {
            const hashed = hash(key);
            return self.getBucket(hashed).getPtrOrPutAndGetPtr(allocator, key, value, hashed);
        }

        pub fn contains(self: *Self, key: K) bool {
            const hashed = hash(K);
            return self.getBucket(hashed).contains(key, hashed);
        }

        inline fn hash(key: K) u64 {
            if (@sizeOf(Context) != 0) {
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ".");
            }
            return @as(Context, undefined).hash(key);
        }
        inline fn getBucket(self: Self, hashed: u64) *Bucket {
            const idx = @mod(hashed, self.buckets.len);
            return &self.buckets[idx];
        }

        const HashMap = std.HashMapUnmanaged(K, V, Context, max_load_percentage);
        pub const KV = HashMap.KV;
        pub const GetOrPutResult = HashMap.GetOrPutResult;

        const Bucket = struct {
            _: void align(std.atomic.cache_line) = {},
            lock: std.Thread.RwLock,
            hash_map: HashMap,

            pub const BucketContext = struct {
                hashed: u64,

                pub fn hash(ctx: BucketContext, key: K) u64 {
                    _ = key;
                    return ctx.hashed;
                }
                pub fn eql(ctx: BucketContext, a: K, b: K) bool {
                    _ = ctx;
                    return std.meta.eql(a, b);
                }
            };

            pub const empty = Bucket{
                .lock = .{},
                .hash_map = .empty,
            };
            pub fn deinit(bucket: *Bucket, allocator: Allocator) void {
                {
                    bucket.lock.lock();
                    defer bucket.lock.unlock();
                    bucket.hash_map.deinit(allocator);
                }
                bucket.* = undefined;
            }

            pub fn get(bucket: *Bucket, key: K, hashed: u64) ?V {
                bucket.lock.lockShared();
                defer bucket.lock.unlockShared();
                return bucket.hash_map.getAdapted(key, BucketContext{ .hashed = hashed });
            }
            pub fn getPtr(bucket: *Bucket, key: K, hashed: u64) ?*V {
                bucket.lock.lockShared();
                defer bucket.lock.unlockShared();
                return bucket.getPtrInner(key, hashed);
            }
            pub fn tryGetPtr(bucket: *Bucket, key: K, hashed: u64) ?*V {
                bucket.lock.tryLockShared();
                defer bucket.lock.unlockShared();
                return bucket.getPtrInner(key, hashed);
            }
            inline fn getPtrInner(bucket: *Bucket, key: K, hashed: u64) ?*V {
                return bucket.hash_map.getPtrAdapted(key, BucketContext{ .hashed = hashed });
            }

            pub fn put(
                bucket: *Bucket,
                allocator: Allocator,
                key: K,
                value: V,
                hashed: u64,
            ) Allocator.Error!void {
                bucket.lock.lock();
                defer bucket.lock.unlock();
                const gop = try bucket.getOrPutInner(allocator, key, hashed);
                gop.value_ptr.* = value;
            }

            pub fn putAndGetPtr(
                bucket: *Bucket,
                allocator: Allocator,
                key: K,
                value: V,
                hashed: u64,
            ) Allocator.Error!*V {
                bucket.lock.lock();
                defer bucket.lock.unlock();
                const gop = try bucket.getOrPutInner(allocator, key, hashed);
                gop.value_ptr.* = value;
                return gop.value_ptr;
            }

            pub fn getPtrOrPutAndGetPtr(
                bucket: *Bucket,
                allocator: Allocator,
                key: K,
                value: V,
                hashed: u64,
            ) Allocator.Error!*V {
                bucket.lock.lock();
                defer bucket.lock.unlock();
                const gop = try bucket.getOrPutInner(allocator, key, hashed);
                if (gop.found_existing == false) {
                    gop.value_ptr.* = value;
                }
                return gop.value_ptr;
            }

            inline fn getOrPutInner(
                bucket: *Bucket,
                allocator: Allocator,
                key: K,
                hashed: u64,
            ) Allocator.Error!GetOrPutResult {
                const gop = try bucket.hash_map.getOrPutAdapted(
                    allocator,
                    key,
                    BucketContext{ .hashed = hashed },
                );
                return gop;
            }

            pub fn contains(bucket: *Bucket, key: K, hashed: u64) bool {
                bucket.lock.lockShared();
                defer bucket.lock.unlockShared();
                return bucket.hash_map.containsContext(key, BucketContext{ .hashed = hashed });
            }
        };
    };
}

pub fn StringArrayHashMapUnmanaged(comptime V: type) type {
    return ArrayHashMapUnmanaged(
        []const u8,
        V,
        std.array_hash_map.StringContext,
        true,
        default_bucket_count,
    );
}

pub fn AutoArrayHashMapUnmanaged(
    comptime K: type,
    comptime V: type,
) type {
    return HashMapUnmanaged(
        K,
        V,
        std.array_hash_map.AutoContext(K),
        !std.array_hash_map.autoEqlIsCheap(K),
        default_bucket_count,
    );
}

pub fn ArrayHashMapUnmanaged(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime store_hash: bool,
    comptime bucket_count: usize,
) type {
    return struct {
        buckets: [bucket_count]Bucket,

        const Self = @This();

        pub const empty = Self{
            .buckets = @splat(.empty),
        };

        pub fn get(self: Self, key: K) ?V {
            const hashed = hash(key);
            return self.getBucket(hashed).get(key, hashed);
        }
        pub fn getPtr(self: Self, key: K) ?*V {
            const hashed = hash(key);
            return self.getBucket(hashed).getPtr(key, hashed);
        }
        pub fn tryGetPtr(self: Self, key: K) ?*V {
            const hashed = hash(key);
            return self.getBucket(hashed).tryGetPtr(key, hashed);
        }
        pub fn getIndex(self: Self, key: K) ?usize {
            const hashed = hash(key);
            return self.getBucket(hashed).getIndex(key, hashed);
        }

        pub fn put(
            self: *Self,
            allocator: Allocator,
            key: K,
            value: V,
        ) Allocator.Error!void {
            const hashed = hash(key);
            try self.getBucket(hashed).put(allocator, key, value, hashed);
        }

        pub fn putAndGetPtr(
            self: *Self,
            allocator: Allocator,
            key: K,
            value: V,
        ) Allocator.Error!*V {
            const hashed = hash(key);
            return self.getBucket(hashed).putAndGetPtr(allocator, key, value, hashed);
        }

        pub fn putAndGetIndex(
            self: *Self,
            allocator: Allocator,
            key: K,
            value: V,
        ) Allocator.Error!usize {
            const hashed = hash(key);
            return self.getBucket(hashed).putAndGetIndex(allocator, key, value, hashed);
        }

        pub fn contains(self: *Self, key: K) bool {
            const hashed = hash(K);
            return self.getBucket(hashed).contains(key, hashed);
        }

        inline fn hash(key: K) u64 {
            if (@sizeOf(Context) != 0) {
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ".");
            }
            return @as(Context, undefined).hash(key);
        }
        inline fn getBucket(self: Self, hashed: u64) *Bucket {
            const idx = @mod(hashed, self.buckets.len);
            return &self.buckets[idx];
        }

        const HashMap = std.ArrayHashMapUnmanaged(K, V, Context, store_hash);
        pub const KV = HashMap.KV;
        pub const GetOrPutResult = HashMap.GetOrPutResult;

        const Bucket = struct {
            _: void align(std.atomic.cache_line) = {},
            lock: std.Thread.RwLock,
            hash_map: HashMap,

            pub const BucketContext = struct {
                hashed: u64,

                pub fn hash(ctx: BucketContext, key: K) u64 {
                    _ = key;
                    return ctx.hashed;
                }
                pub fn eql(ctx: BucketContext, a: K, b: K) bool {
                    _ = ctx;
                    return std.meta.eql(a, b);
                }
            };

            pub const empty = Bucket{
                .lock = .{},
                .hash_map = .empty,
            };
            pub fn deinit(bucket: *Bucket, allocator: Allocator) void {
                {
                    bucket.lock.lock();
                    defer bucket.lock.unlock();
                    bucket.hash_map.deinit(allocator);
                }
                bucket.* = undefined;
            }

            pub fn get(bucket: *Bucket, key: K, hashed: u64) ?V {
                bucket.lock.lockShared();
                defer bucket.lock.unlockShared();
                return bucket.hash_map.getAdapted(key, BucketContext{ .hashed = hashed });
            }
            pub fn getPtr(bucket: *Bucket, key: K, hashed: u64) ?*V {
                bucket.lock.lockShared();
                defer bucket.lock.unlockShared();
                return bucket.getPtrInner(key, hashed);
            }
            pub fn tryGetPtr(bucket: *Bucket, key: K, hashed: u64) ?*V {
                bucket.lock.tryLockShared();
                defer bucket.lock.unlockShared();
                return bucket.getPtrInner(key, hashed);
            }
            inline fn getPtrInner(bucket: *Bucket, key: K, hashed: u64) ?*V {
                return bucket.hash_map.getPtrAdapted(key, BucketContext{ .hashed = hashed });
            }

            pub fn getIndex(bucket: *Bucket, key: K, hashed: u64) ?usize {
                bucket.lock.lockShared();
                defer bucket.lock.unlockShared();
                return bucket.hash_map.getIndexAdapted(key, BucketContext{ .hashed = hashed });
            }

            pub fn put(
                bucket: *Bucket,
                allocator: Allocator,
                key: K,
                value: V,
                hashed: u64,
            ) Allocator.Error!void {
                bucket.lock.lock();
                defer bucket.lock.unlock();
                const gop = try bucket.getOrPutInner(allocator, key, hashed);
                gop.value_ptr.* = value;
            }

            pub fn putAndGetPtr(
                bucket: *Bucket,
                allocator: Allocator,
                key: K,
                value: V,
                hashed: u64,
            ) Allocator.Error!*V {
                bucket.lock.lock();
                defer bucket.lock.unlock();
                const gop = try bucket.getOrPutInner(allocator, key, hashed);
                gop.value_ptr.* = value;
                return gop.value_ptr;
            }

            pub fn putAndGetIndex(
                bucket: *Bucket,
                allocator: Allocator,
                key: K,
                value: V,
                hashed: u64,
            ) Allocator.Error!usize {
                bucket.lock.lock();
                defer bucket.lock.unlock();
                const gop = try bucket.getOrPutInner(allocator, key, hashed);
                gop.value_ptr.* = value;
                return gop.index;
            }

            inline fn getOrPutInner(
                bucket: *Bucket,
                allocator: Allocator,
                key: K,
                hashed: u64,
            ) Allocator.Error!GetOrPutResult {
                const gop = try bucket.hash_map.getOrPutAdapted(
                    allocator,
                    key,
                    BucketContext{ .hashed = hashed },
                );
                return gop;
            }

            pub fn contains(bucket: *Bucket, key: K, hashed: u64) bool {
                bucket.lock.lockShared();
                defer bucket.lock.unlockShared();
                return bucket.hash_map.containsContext(key, BucketContext{ .hashed = hashed });
            }
        };
    };
}
