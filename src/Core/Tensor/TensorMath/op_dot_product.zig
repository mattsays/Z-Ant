const std = @import("std");
const Tensor = @import("tensor").Tensor; // Import Tensor type
const pkg_allocator = @import("pkgAllocator").allocator;

const ArchitectureError = @import("errorHandler").ArchitectureError;
const TensorMathError = @import("errorHandler").TensorMathError;

// DOT PRODUCT -----------------------------------------------------------------------------------------------------------------------

/// Implementation of dot product for CPU architecture still not parallelized
/// This optimized version improves performance through:
/// 1. Flat iteration instead of recursion (eliminates call stack overhead)
/// 2. Direct memory access vs get/set methods (removes function call overhead)
/// 3. Cache-friendly memory access patterns
/// 4. SIMD-friendly inner loop structure
pub fn dot_product_tensor(comptime inputType: anytype, comptime outputType: anytype, t1: *Tensor(inputType), t2: *Tensor(inputType)) !Tensor(outputType) {
    //CHECKS remain the same
    const nDimT1 = t1.shape.len;
    const nDimT2 = t2.shape.len;
    if (nDimT1 != nDimT2) return TensorMathError.InputTensorDifferentShape;
    if (t1.shape[nDimT1 - 1] != t2.shape[nDimT1 - 2]) return TensorMathError.InputTensorsWrongShape;

    if (@TypeOf(outputType) == @TypeOf(inputType)) {
        // Skip check if same type
    } else {
        if (@bitSizeOf(outputType) <= 16) {
            if (@bitSizeOf(outputType) <= (@bitSizeOf(inputType) * 2)) return TensorMathError.TooSmallOutputType;
        } else {
            if (@bitSizeOf(outputType) <= @bitSizeOf(inputType)) return TensorMathError.TooSmallOutputType;
        }
    }

    const allocator = pkg_allocator;
    var out_shape = try allocator.alloc(usize, nDimT1);
    defer allocator.free(out_shape);

    // Pre-calculate total iterations to avoid repeated multiplications in the loop
    // This reduces runtime computation overhead
    var total_outer_iterations: usize = 1;
    for (0..(nDimT1 - 2)) |i| {
        out_shape[i] = t1.shape[i];
        total_outer_iterations *= t1.shape[i];
    }
    out_shape[nDimT1 - 2] = t1.shape[nDimT1 - 2];
    out_shape[nDimT1 - 1] = t2.shape[nDimT1 - 1];
    total_outer_iterations *= t1.shape[nDimT1 - 2] * t2.shape[nDimT1 - 1];

    var out_tensor = try Tensor(outputType).fromShape(&allocator, out_shape);
    errdefer out_tensor.deinit();

    // Pre-calculate strides to:
    // 1. Avoid repeated calculations in loops
    // 2. Enable direct memory access with simple offset arithmetic
    // 3. Make memory access patterns more predictable for CPU cache
    const inner_dim = t1.shape[nDimT1 - 1];
    const t1_stride = t1.shape[nDimT1 - 1];
    const t2_stride = t2.shape[nDimT1 - 1];
    const out_stride = out_tensor.shape[nDimT1 - 1];

    // Single flat loop instead of nested loops reduces:
    // 1. Branch prediction misses
    // 2. Loop overhead
    // 3. Stack frame management
    var batch_idx: usize = 0;
    while (batch_idx < total_outer_iterations) : (batch_idx += 1) {
        // Efficient index calculation using modulo and division
        // Replaces complex recursive index tracking
        const out_row = (batch_idx / out_stride) % out_tensor.shape[nDimT1 - 2];
        const out_col = batch_idx % out_stride;

        var sum: outputType = 0;
        // Pre-calculate offsets for inner loop efficiency
        const row_offset = out_row * t1_stride;
        const col_offset = out_col;

        // Inner loop optimized for:
        // 1. SIMD vectorization (simple increment, no complex indexing)
        // 2. Cache locality (sequential memory access)
        // 3. Branch prediction (simple condition)
        var k: usize = 0;
        while (k < inner_dim) : (k += 1) {
            // Direct memory access instead of get_at() calls
            // Eliminates function call overhead and bounds checking
            const t1_val = t1.data[row_offset + k];
            const t2_val = t2.data[k * t2_stride + col_offset];
            sum += t1_val * t2_val;
        }

        out_tensor.data[batch_idx] = sum;
    }

    return out_tensor;
}

/// Function that performs the multiplication of two tensors used in a recursive way to handle multidimensional tensors
fn multidim_multiplication(comptime inputType: anytype, comptime outputType: anytype, t1: *Tensor(inputType), t2: *Tensor(inputType), t3: *Tensor(outputType), current_depth: usize, location: []usize) !void {
    if (current_depth == (t1.shape.len - 2)) {

        //declaring sum
        var sum: outputType = 0;

        //with the first two for loop I iterate over t3
        for (0..t1.shape[current_depth]) |row| { //for each row of t1

            for (0..t2.shape[current_depth + 1]) |col| { //for each col of t2

                sum = 0;

                for (0..t1.shape[current_depth + 1]) |i| {

                    //compose the location on t1
                    location[t1.shape.len - 1] = i; //location
                    location[t1.shape.len - 2] = row; //location

                    //getting the correct numbers in t1
                    const a = try t1.get_at(location);

                    //compose the location on t2
                    location[t1.shape.len - 1] = col; //location
                    location[t1.shape.len - 2] = i; //location

                    //getting the correct numbers in t2
                    const b = try t2.get_at(location);

                    sum += a * b;
                }

                //compose the location on t3
                location[t1.shape.len - 1] = col; //col on the out tensor matrix
                location[t1.shape.len - 2] = row; //row on the out tensor matrix

                try t3.set_at(location, sum);
            }
        }
    } else {
        for (0..t1.shape[current_depth]) |element_at_current_depth| {
            //print location:
            //std.debug.print("\n depth: {} element_at_current_depth: {}", .{ current_depth, element_at_current_depth });
            location[current_depth] = element_at_current_depth;
            //otherwise I have to go deeper
            try multidim_multiplication(
                inputType,
                outputType,
                t1,
                t2,
                t3,
                current_depth + 1,
                location,
            );
        }
    }
}
