const std = @import("std");
const Tensor = @import("tensor").Tensor;
//import error libraries
const TensorError = @import("errorHandler").TensorError;
const TensorMathError = @import("errorHandler").TensorMathError;

pub const ActivationType = enum {
    ReLU,
    Sigmoid,
    Softmax,
    None,
    LeakyReLU,
};

/// Activation function Interface, used to instantiate a Loss Function struct
/// depending on the ActivationType passed by argument.
pub fn ActivationFunction(comptime T: anytype, activationType: ActivationType) type {
    return switch (activationType) {
        ActivationType.ReLU => ReLU(T),
        ActivationType.Sigmoid => Sigmoid(T),
        ActivationType.Softmax => Softmax(T),
        ActivationType.LeakyReLU => LeakyReLU(T),
        ActivationType.None => None(),
    };
}

/// Used when no activation functio is needed
pub fn None() type {}

/// ReLU (Rectified Linear Unit).
/// It outputs the input directly if it's positive, but returns zero for any negative input.
pub fn ReLU(comptime T: anytype) type {
    return struct {
        const Self = @This();

        //it directly modify the input tensor
        //threshold is usually set to zero
        pub fn forward(self: *Self, input: *Tensor(T)) !void {
            _ = self;

            //checks
            if (input.size <= 0) return TensorError.ZeroSizeTensor;

            //apply ReLU
            //OSS: can be improved, see how did I parallelized CPU Tensor Sum
            for (0..input.size) |i| {
                if (input.data[i] <= 0) input.data[i] = 0;
            }
        }

        pub fn derivate(self: *Self, gradient: *Tensor(T), act_relu_input: *Tensor(T)) !void {
            _ = self;
            //checks
            if (gradient.size <= 0 or act_relu_input.size <= 0) return TensorError.ZeroSizeTensor;
            if (gradient.size != act_relu_input.size) return TensorMathError.InputTensorDifferentSize;

            //apply ReLU
            //OSS: can be improved, see how did I parallelized CPU Tensor Sum
            for (0..(gradient.size - 1)) |i| {
                if (act_relu_input.data[i] <= 0) {
                    gradient.data[i] = 0;
                }
            }
        }
    };
}
/// Leaky ReLU is a variant of ReLU that allows a small, positive gradient when the input is negative.
/// This can help prevent the dying ReLU problem, where neurons stop learning if they get stuck in the negative side of the ReLU function.
/// The leaky parameter is a small value that determines how much the function leaks into the negative side.
/// A common value for the leaky parameter is 0.01.
/// The Leaky ReLU function is defined as:
/// f(x) = x if x > 0
/// f(x) = alpha * x if x <= 0
/// where alpha is a small constant.
/// The derivative of the Leaky ReLU function is:
/// f'(x) = 1 if x > 0
/// f'(x) = alpha if x <= 0
pub fn LeakyReLU(comptime T: anytype) type {
    return struct {
        const Self = @This();
        pub fn forward(self: *Self, input: *Tensor(T), slope: T) !void {
            _ = self;

            //checks
            if (input.size <= 0) return TensorError.ZeroSizeTensor;

            //apply Leaky ReLU suing relu self.relu() - (-neg_slope*self).relu()
            for (0..input.size) |i| {
                if (input.data[i] <= 0) {
                    input.data[i] = slope * input.data[i];
                }
            }
        }

        pub fn derivate(self: *Self, gradient: *Tensor(T), act_relu_input: *Tensor(T), slope: T) !void {
            _ = self;
            //checks
            if (gradient.size <= 0 or act_relu_input.size <= 0) return TensorError.ZeroSizeTensor;
            if (gradient.size != act_relu_input.size) return TensorMathError.InputTensorDifferentSize;

            //apply Leaky ReLU
            for (0..gradient.size) |i| {
                if (act_relu_input.data[i] > 0) {
                    gradient.data[i] *= 1;
                } else {
                    gradient.data[i] *= slope;
                }
            }
        }
    };
}

/// The Sigmoid activation function is a smooth, S-shaped function that maps any input
/// to a value between 0 and 1.
/// it can suffer from vanishing gradients, especially for large positive or negative
/// inputs, slowing down training in deep networks.
pub fn Sigmoid(comptime T: anytype) type {
    return struct {
        const Self = @This();
        //it directly modify the input tensor
        pub fn forward(self: *Self, input: *Tensor(T)) !void {
            _ = self;
            //checks
            if (input.size <= 0) return TensorError.ZeroSizeTensor;

            //apply Sigmoid
            for (0..input.size) |i| {
                input.data[i] = 1.0 / (1.0 + @exp(-input.data[i]));
            }
        }

        pub fn derivate(self: *Self, gradient: *Tensor(T), act_forward_out: *Tensor(T)) !void {
            _ = self;
            //checks
            if (gradient.size <= 0 or act_forward_out.size <= 0) return TensorError.ZeroSizeTensor;
            if (gradient.size != act_forward_out.size) return TensorMathError.InputTensorDifferentSize;

            //apply Sigmoid
            for (0..gradient.size) |i| {
                gradient.data[i] = gradient.data[i] * act_forward_out.data[i] * (1.0 - act_forward_out.data[i]);
            }
        }
    };
}

const pkg_allocator = @import("pkgAllocator").allocator;

/// The Softmax activation function is used in multi-class classification tasks to convert
/// logits (raw output values) into probabilities that sum to 1.
/// Ideal for output layers in multi-class neural networks.
pub fn Softmax(comptime T: anytype) type {
    return struct {
        const Self = @This();
        //it directly modify the input tensor
        pub fn forward(self: *Self, input: *Tensor(T)) !void {
            _ = self;
            const allocator = pkg_allocator;

            const location = try allocator.alloc(usize, input.shape.len);
            defer allocator.free(location);

            //fill starting location to all zeros
            for (0..input.shape.len) |i| {
                location[i] = 0;
            }

            //try compute_mutidim_softmax(input, 0, location);
            try compute_2D_softmax(input);
        }

        fn compute_2D_softmax(input: *Tensor(T)) !void {
            const rows = input.shape[0];
            const cols = input.shape[1];

            var max_val: T = undefined;
            var sum_of_exp: T = 0.0;
            var val: T = undefined;

            // For each row
            for (0..rows) |i| {
                // Find the maximum value in the row to stabilize the computation
                max_val = input.data[i * cols];
                for (0..cols) |j| {
                    val = input.data[i * cols + j];
                    if (val > max_val) {
                        max_val = val;
                    }
                }

                // Compute stabilized exponentials and their sum
                sum_of_exp = 0.0;
                for (0..cols) |j| {
                    val = input.data[i * cols + j] - max_val; // Stabilization
                    val = @exp(val);
                    input.data[i * cols + j] = val;
                    sum_of_exp += val;
                }

                // Normalize to calculate the softmax
                for (0..cols) |j| {
                    input.data[i * cols + j] /= sum_of_exp;
                }
            }
        }

        //TODO: now scan the rows of the matrix, it must scan the columns
        fn compute_mutidim_softmax(input: *Tensor(T), current_depth: usize, location: []usize) !void {
            if (current_depth == (input.shape.len - 1)) {
                //declaring res as the result of the sum of the MSE
                const allocator = pkg_allocator;

                //get location is used just to manage the gets and sets relative to the current depth
                const get_location = try allocator.alloc(usize, location.len);
                defer allocator.free(get_location);
                //initializing get location to the same values of location
                for (0..get_location.len) |i| {
                    get_location[i] = location[i];
                }

                //input.info();

                //allocating space for the exponent of each value
                var sum_of_exp: T = 0.0;
                var val: T = undefined;
                var exp: T = undefined;

                //calculating the value of the exponential for each element
                for (0..input.shape[current_depth]) |i| {
                    get_location[current_depth] = i; //for each element of predictions vect and target vect
                    val = try input.get_at(get_location);
                    exp = @exp(val);
                    try input.set_at(get_location, exp);
                    sum_of_exp += exp;
                }

                //set the value of current_elem/sum_of_exp
                for (0..input.shape[current_depth]) |i| {
                    get_location[current_depth] = i; //for each element of predictions vect and target vect
                    val = try input.get_at(get_location);
                    val = val / sum_of_exp;
                    try input.set_at(get_location, val);
                }
            } else {
                for (0..input.shape[current_depth]) |element_at_current_depth| {
                    //print depth:
                    //std.debug.print("\n depth: {} element_at_current_depth: {}", .{ current_depth, element_at_current_depth });
                    location[current_depth] = element_at_current_depth;
                    //otherwise I have to go deeper
                    try compute_mutidim_softmax(
                        input,
                        current_depth + 1,
                        location,
                    );
                }
            }
        }

        pub fn derivate(self: *Self, dL_dX: *Tensor(T), softmax_output: *Tensor(T)) !void {
            _ = self;
            // softmax_output: The output matrix from the Softmax forward pass.
            // dL_dS: The gradient of the loss with respect to the Softmax output (this is given to us during backpropagation).
            // dL_dX: The gradient of the loss with respect to the input matrix (this is what we are computing in the backward pass).

            //checks
            if (dL_dX.size <= 0) return TensorError.ZeroSizeTensor;

            const dim = dL_dX.shape.len;
            const rows = dL_dX.shape[dim - 2];
            const cols = dL_dX.shape[dim - 1];

            var dL_dS = try dL_dX.copy(); //the copy is necessary since we are going to modify dL_dX
            defer dL_dS.deinit();

            // Loop over each row (assuming we apply Softmax across rows)
            for (0..rows) |i| {
                // Loop over each element in the row
                for (0..cols) |j| {
                    var dL_dX_ij: T = 0;

                    // Calculate the gradient for input element x_ij
                    const softmax_j = softmax_output.data[i * cols + j];

                    // Sum over all elements in the row to compute dL/dX_ij
                    for (0..cols) |k| {
                        const softmax_k = softmax_output.data[i * cols + k];
                        const dL_dS_k = dL_dS.data[i * cols + k];

                        if (j == k) {
                            dL_dX_ij += dL_dS_k * softmax_k * (1 - softmax_j);
                        } else {
                            dL_dX_ij += dL_dS_k * -softmax_k * softmax_j;
                        }
                    }

                    // Store the computed gradient for input x_ij
                    dL_dX.data[i * cols + j] = dL_dX_ij;
                }
            }
        }
    };
}
