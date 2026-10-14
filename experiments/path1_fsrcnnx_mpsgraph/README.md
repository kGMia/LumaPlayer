# Unvalidated historical experiment

These binaries are a regex extraction of shader literals, including non-weight values. The manifest describes a different network and cannot be used for FSRCNNX inference. They are no longer bundled in the player. Preserve for audit only; do not use the previous performance/quality numbers as measurements.

A real port must parse each shader pass (weights, biases, activations, residual connections and the exact subpixel channel order), reconstruct its computation, and compare outputs to GLSL before being exposed as an available model.
