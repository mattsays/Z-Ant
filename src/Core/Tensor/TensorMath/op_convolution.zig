const std = @import("std");
const Tensor = @import("tensor").Tensor; // Import Tensor type
const pkg_allocator = @import("pkgAllocator").allocator;
const TensorMathError = @import("errorHandler").TensorMathError;
const dot_product_tensor = @import("op_dot_product.zig").dot_product_tensor;

// CONVOLVE -----------------------------------------------------------------------------------------------------------------------

/// Multidim Conv
/// INPUT:
///     INPUT[input.shape.len - 4] -> batches
///     INPUT[input.shape.len - 3] -> input channels
///     INPUT[input.shape.len - 2] -> rows
///     INPUT[input.shape.len - 1] -> cols
/// KERNEL:
///     KERNEL[kernel.shape.len - 4] -> filters
///     KERNEL[kernel.shape.len - 3] -> channels
///     KERNEL[kernel.shape.len - 2] -> rows
///     KERNEL[kernel.shape.len - 1] -> cols
/// OUTPUT:
///     OUTPUT[output.shape.len - 4] -> input_batch
///     OUTPUT[output.shape.len - 3] -> output channels (number_of_kernel_filters)
///     OUTPUT[output.shape.len - 2] -> rows
///     OUTPUT[output.shape.len - 1] -> cols
/// Convolution tensor with bias
/// TODO: create 2d convolution, atm is 3 or more dimensions
/// TODO: add better check on output size wrt input and kernel
pub fn convolve_tensor_with_bias(
    comptime T: type,
    input: *Tensor(T),
    kernel: *const Tensor(T),
    bias: *const Tensor(T),
    stride: []const usize, // shape:[row_stride, column_stride]
) !Tensor(T) {
    const nDimInput = input.shape.len;
    const nDimKernel = kernel.shape.len;
    const nDimBias = bias.shape.len;

    //chck on dimensions
    if (nDimKernel > nDimInput) {
        std.debug.print("Error: Kernel size must be smaller or equal to Input size, Kernel size:{}, Input size:{}\n", .{ nDimKernel, nDimInput });
        return TensorMathError.InputTensorDifferentShape;
    }

    //check on input tensor and kernel number of channels, one channel for each filter
    if (input.shape[nDimInput - 3] != kernel.shape[nDimKernel - 3]) {
        std.debug.print("Error: Mismatched channels. Input: {d}, Kernel: {d}\n", .{ input.shape[nDimInput - 3], kernel.shape[nDimKernel - 3] });
        return TensorMathError.InputTensorsWrongShape;
    }

    //check on input tensor and kernel number of rows
    if (kernel.shape[nDimKernel - 2] > input.shape[nDimInput - 2]) {
        std.debug.print("Error: Kernel too big, Input rows: {d}, Kernel rows: {d}\n", .{ input.shape[nDimInput - 2], kernel.shape[nDimKernel - 2] });
        return TensorMathError.InputTensorsWrongShape;
    }

    //check on input tensor and kernel number of cols
    if (kernel.shape[nDimKernel - 1] > input.shape[nDimInput - 1]) {
        std.debug.print("Error: Kernel too big, Input cols: {d}, Kernel cols: {d}\n", .{ input.shape[nDimInput - 2], kernel.shape[nDimKernel - 2] });
        return TensorMathError.InputTensorsWrongShape;
    }

    //check there is one bias for each kernel filter
    if (bias.shape[nDimBias - 1] != kernel.shape[nDimKernel - 4]) {
        std.debug.print("Error: wrong number of biases, # Biases:{}, # Kernel filters:{d}\n", .{ bias.shape.len, kernel.shape[nDimKernel - 3] });
        return TensorMathError.InputTensorsWrongShape;
    }

    //check on the stride size
    if (stride.len != 2) {
        std.debug.print("Error: wrong stride size\n", .{});
        return TensorMathError.WrongStride;
    }
    //check not zero stride
    if (stride[0] == 0 or stride[1] == 0) {
        std.debug.print("Error: stride cannot be zero\n", .{});
        return TensorMathError.WrongStride;
    }

    // Convert input to im2col format
    const kernel_size = [2]usize{ kernel.shape[2], kernel.shape[3] };
    const stride_size = [2]usize{ stride[0], stride[1] };
    var input_col = try im2col(T, input, kernel_size, stride_size);
    defer input_col.deinit();

    // Reshape kernel to 2D matrix [channels * kernel_h * kernel_w, num_filters]
    const num_filters = kernel.shape[0];
    const kernel_elements = kernel.shape[1] * kernel.shape[2] * kernel.shape[3];
    var kernel_matrix_shape = [_]usize{ kernel_elements, num_filters };
    var kernel_matrix = try Tensor(T).fromShape(&pkg_allocator, &kernel_matrix_shape);
    defer kernel_matrix.deinit();

    // Copy and transpose kernel data to reshaped matrix
    for (0..num_filters) |f| {
        for (0..kernel_elements) |i| {
            try kernel_matrix.set_at(&[_]usize{ i, f }, kernel.data[f * kernel_elements + i]);
        }
    }

    // Perform matrix multiplication
    const batch_size = input.shape[0];
    const out_height = (input.shape[2] - kernel.shape[2]) / stride[0] + 1;
    const out_width = (input.shape[3] - kernel.shape[3]) / stride[1] + 1;
    // Result will be [batch_size * out_height * out_width, num_filters]
    var result = try dot_product_tensor(T, T, &input_col, &kernel_matrix);
    defer result.deinit();

    // Reshape result to proper output format [batch_size, num_filters, out_height, out_width]
    var output_shape = [_]usize{ batch_size, num_filters, out_height, out_width };
    var output = try Tensor(T).fromShape(&pkg_allocator, &output_shape);
    errdefer output.deinit();

    // Copy data to output tensor and add bias
    var idx: usize = 0;
    for (0..batch_size) |b| {
        for (0..out_height) |h| {
            for (0..out_width) |w| {
                for (0..num_filters) |f| {
                    const val = try result.get_at(&[_]usize{ idx, f });
                    const bias_val = bias.data[f]; // Direct access to bias data since we know it's a 1D tensor
                    try output.set_at(&[_]usize{ b, f, h, w }, val + bias_val);
                }
                idx += 1;
            }
        }
    }

    return output;
}

pub fn convolution_backward_biases(comptime T: type, dValues: *Tensor(T)) !Tensor(T) {
    // Compute gradients with respect to biases by summing over batch, height, and width dimensions
    // Assumes dValues shape: [batch_size, out_channels (aka number of kernel filters), output_height, output_width]

    // Check that dValues has at least 4 dimensions
    if (dValues.shape.len < 4) return TensorMathError.InputTensorsWrongShape;

    const out_channels = dValues.shape[1];
    var bias_gradients_shape = [_]usize{out_channels};

    // Allocate the bias_gradients tensor
    var bias_gradients = try Tensor(T).fromShape(&pkg_allocator, &bias_gradients_shape);
    errdefer bias_gradients.deinit();
    try bias_gradients.set(0, 0); // Initialize to zero

    const batch_size = dValues.shape[0];
    const output_height = dValues.shape[2];
    const output_width = dValues.shape[3];

    // Sum over batch, height, and width dimensions
    for (0..out_channels) |oc| {
        for (0..batch_size) |b| {
            for (0..output_height) |h| {
                for (0..output_width) |w| {
                    const val = try dValues.get_at(&[_]usize{ b, oc, h, w });
                    const current = try bias_gradients.get_at(&[_]usize{oc});
                    try bias_gradients.set_at(&[_]usize{oc}, current + val);
                }
            }
        }
    }

    return bias_gradients;
}

pub fn convolution_backward_weights(comptime T: type, input: *Tensor(T), dvalues: *Tensor(T), kernel_shape: []const usize, stride: [2]usize) !Tensor(T) {
    const batch_size = input.shape[0];
    const num_filters = kernel_shape[0];
    const kernel_height = kernel_shape[2];
    const kernel_width = kernel_shape[3];

    // Converte input in formato im2col
    const kernel_size = [2]usize{ kernel_height, kernel_width };
    var input_col = try im2col(T, input, kernel_size, stride);
    defer input_col.deinit();

    const out_height = dvalues.shape[2];
    const out_width = dvalues.shape[3];
    const total_spatial = out_height * out_width;

    // Reshape ottimizzato di dValues
    var dval_shape = [_]usize{ num_filters, batch_size * total_spatial };
    var dval_reshaped = try Tensor(T).fromShape(&pkg_allocator, &dval_shape);
    defer dval_reshaped.deinit();

    // Copia dati in modo efficiente
    for (0..batch_size) |b| {
        for (0..num_filters) |f| {
            for (0..total_spatial) |i| {
                const src_idx = b * num_filters * total_spatial + f * total_spatial + i;
                const dst_idx = f * batch_size * total_spatial + b * total_spatial + i;
                try dval_reshaped.set_at(&[_]usize{ f, dst_idx % (batch_size * total_spatial) }, dvalues.data[src_idx]);
            }
        }
    }
    // Calcola gradiente e media sul batch
    var dW = try dot_product_tensor(T, T, &dval_reshaped, &input_col);
    defer dW.deinit();

    // IMPORTANTE: Media sul batch
    const batch_size_f = @as(T, @floatFromInt(batch_size));
    for (dW.data) |*val| {
        val.* /= batch_size_f;
    }

    // Reshape al formato kernel originale
    var dW_shape: [4]usize = undefined;
    @memcpy(&dW_shape, kernel_shape);
    const dW_reshaped = try Tensor(T).fromShape(&pkg_allocator, &dW_shape);
    @memcpy(dW_reshaped.data, dW.data);

    return dW_reshaped;
}

pub fn convolution_backward_input(comptime T: type, dvalues: *const Tensor(T), kernel: *const Tensor(T), input_shape: []const usize, stride: [2]usize) !Tensor(T) {
    std.debug.print("\n=== Convolution Backward Input Debug ===\n", .{});
    std.debug.print("Input shape: {any}\n", .{input_shape});
    std.debug.print("dValues shape: {any}\n", .{dvalues.shape});
    std.debug.print("Kernel shape: {any}\n", .{kernel.shape});
    std.debug.print("Stride: {any}\n", .{stride});

    const batch_size = input_shape[0];
    const channels = input_shape[1];
    const num_filters = kernel.shape[0];
    const kernel_height = kernel.shape[2];
    const kernel_width = kernel.shape[3];

    const out_height = dvalues.shape[2];
    const out_width = dvalues.shape[3];
    const total_spatial = out_height * out_width;

    // Reshape dValues to [batch_size * out_height * out_width, num_filters]
    var dval_shape = [_]usize{ batch_size * total_spatial, num_filters };
    std.debug.print("\ndValues reshape: {any}\n", .{dval_shape});
    var dval_reshaped = try Tensor(T).fromShape(&pkg_allocator, &dval_shape);
    defer dval_reshaped.deinit();

    // Copy data efficiently
    for (0..batch_size) |b| {
        for (0..total_spatial) |i| {
            for (0..num_filters) |f| {
                const h = i / out_width;
                const w = i % out_width;
                const src_idx = b * num_filters * total_spatial + f * total_spatial + h * out_width + w;
                const dst_idx = b * total_spatial + i;
                try dval_reshaped.set_at(&[_]usize{ dst_idx, f }, dvalues.data[src_idx]);
            }
        }
    }

    // Create transposed kernel [num_filters, channels * kernel_height * kernel_width]
    const kernel_spatial = kernel_height * kernel_width;
    var transposed_shape = [_]usize{ num_filters, channels * kernel_spatial };
    std.debug.print("\nKernel transposed shape: {any}\n", .{transposed_shape});
    var kernel_transposed = try Tensor(T).fromShape(&pkg_allocator, &transposed_shape);
    defer kernel_transposed.deinit();

    // Copy and transpose kernel data
    for (0..num_filters) |f| {
        for (0..channels) |c| {
            for (0..kernel_spatial) |k| {
                const src_idx = f * channels * kernel_spatial + c * kernel_spatial + k;
                const dst_idx = c * kernel_spatial + k;
                try kernel_transposed.set_at(&[_]usize{ f, dst_idx }, kernel.data[src_idx]);
            }
        }
    }

    std.debug.print("\nDot product shapes:\ndval_reshaped: {any}\nkernel_transposed: {any}\n", .{ dval_reshaped.shape, kernel_transposed.shape });
    // Calculate input gradient [batch_size * out_height * out_width, channels * kernel_height * kernel_width]
    var dX_col = try dot_product_tensor(T, T, &dval_reshaped, &kernel_transposed);
    defer dX_col.deinit();

    // Convert back to input format
    const kernel_size = [2]usize{ kernel_height, kernel_width };
    return try col2im(T, &dX_col, input_shape, kernel_size, stride);
}

// --------------------------------------------------
// --------------------- im2col ---------------------
// --------------------------------------------------
// --------- standard im2col
pub fn im2col(comptime T: type, input: *Tensor(T), kernel: [2]usize, stride: [2]usize) !Tensor(T) {

    //check on dimensions
    if (input.shape.len != 4) {
        return TensorMathError.InputTensorsWrongShape;
    }

    // Output matrix dimensions
    const batch_size = input.shape[0];
    const channels = input.shape[1];
    const height = input.shape[2];
    const width = input.shape[3];

    const kernel_h = kernel[0];
    const kernel_w = kernel[1];
    const stride_h = stride[0];
    const stride_w = stride[1];

    const out_height = (height - kernel_h) / stride_h + 1;
    const out_width = (width - kernel_w) / stride_w + 1;

    const rows = batch_size * out_height * out_width;
    const cols = channels * kernel_h * kernel_w;

    var col_shape = [_]usize{ rows, cols };
    var col_matrix = try Tensor(T).fromShape(&pkg_allocator, &col_shape);

    try lean_im2col(T, input, kernel, stride, &col_matrix);

    return col_matrix;
}
// --------- lean im2col
pub inline fn lean_im2col(comptime T: type, input: *Tensor(T), kernel: [2]usize, stride: [2]usize, output: *Tensor(T)) !void {
    const batch_size = input.shape[0];
    const channels = input.shape[1];
    const height = input.shape[2];
    const width = input.shape[3];

    const kernel_h = kernel[0];
    const kernel_w = kernel[1];
    const stride_h = stride[0];
    const stride_w = stride[1];

    const out_height = (height - kernel_h) / stride_h + 1;
    const out_width = (width - kernel_w) / stride_w + 1;

    var row: usize = 0;
    for (0..batch_size) |b| {
        for (0..out_height) |oh| {
            for (0..out_width) |ow| {
                var col: usize = 0;
                for (0..channels) |c| {
                    for (0..kernel_h) |kh| {
                        for (0..kernel_w) |kw| {
                            const h_offset = oh * stride_h + kh;
                            const w_offset = ow * stride_w + kw;
                            const input_idx = b * channels * height * width +
                                c * height * width +
                                h_offset * width +
                                w_offset;
                            try output.set_at(&[_]usize{ row, col }, input.data[input_idx]);
                            col += 1;
                        }
                    }
                }
                row += 1;
            }
        }
    }
}

/// Converts a 2D matrix back to a 4D tensor using col2im algorithm
/// Input shape: [batch_size * out_height * out_width, channels * kernel_height * kernel_width]
/// Output shape: [batch_size, channels, height, width]
pub fn col2im(comptime T: type, col_matrix: *Tensor(T), output_shape: []const usize, kernel: [2]usize, stride: [2]usize) !Tensor(T) {

    //checks
    if (output_shape.len != 4) {
        std.debug.print("ERROR: wrong output shape len. Your output shape len is {} but only 4 is accepted \n", .{output_shape.len});
        return TensorMathError.InvalidDimensions;
    }

    var shape: [4]usize = undefined;
    for (0..4) |i| {
        shape[i] = output_shape[i];
    }

    // Create and Initialize to zero
    var output = try Tensor(T).fromShape(&pkg_allocator, &shape);

    try lean_col2im(T, col_matrix, output_shape, kernel, stride, &output);

    return output;
}

pub inline fn lean_col2im(comptime T: type, col_matrix: *Tensor(T), output_shape: []const usize, kernel: [2]usize, stride: [2]usize, output: *Tensor(T)) !void {
    const batch_size = output_shape[0];
    const channels = output_shape[1];
    const height = output_shape[2];
    const width = output_shape[3];

    const kernel_h = kernel[0];
    const kernel_w = kernel[1];
    const stride_h = stride[0];
    const stride_w = stride[1];

    const out_height = (height - kernel_h) / stride_h + 1;
    const out_width = (width - kernel_w) / stride_w + 1;

    var row: usize = 0;
    for (0..batch_size) |b| {
        for (0..out_height) |oh| {
            for (0..out_width) |ow| {
                var col: usize = 0;
                for (0..channels) |c| {
                    for (0..kernel_h) |kh| {
                        for (0..kernel_w) |kw| {
                            const h_offset = oh * stride_h + kh;
                            const w_offset = ow * stride_w + kw;
                            const output_idx = b * channels * height * width +
                                c * height * width +
                                h_offset * width +
                                w_offset;
                            const val = try col_matrix.get_at(&[_]usize{ row, col });
                            output.data[output_idx] += val;
                            col += 1;
                        }
                    }
                }
                row += 1;
            }
        }
    }
}
