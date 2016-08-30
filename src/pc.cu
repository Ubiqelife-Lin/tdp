
#include <tdp/image.h>
#include <tdp/camera.h>
#include <tdp/eigen/dense.h>

namespace tdp {

__global__ void KernelDepth2PC(
    Image<float> d,
    Camera<float> cam,
    Image<Vector3fda> pc
    ) {
  const int idx = threadIdx.x + blockDim.x * blockIdx.x;
  const int idy = threadIdx.y + blockDim.y * blockIdx.y;
  if (idx < pc.w_ && idy < pc.h_) {
    const float di = d(idx,idy);
    if (di > 0) {
      pc(idx,idy) = cam.Unproject(idx,idy,di);
    } else {
      pc(idx,idy)(0) = 0./0.; // nan
      pc(idx,idy)(1) = 0./0.; // nan
      pc(idx,idy)(2) = 0./0.; // nan
    }
  } else if (idx < d.w_ && idy < d.h_) {
    // d might be bigger than pc because of consecutive convolutions
    pc(idx,idy)(0) = 0./0.; // nan
    pc(idx,idy)(1) = 0./0.; // nan
    pc(idx,idy)(2) = 0./0.; // nan
  }
}

void Depth2PC(
    const Image<float>& d,
    const Camera<float>& cam,
    Image<Vector3fda>& pc
    ) {

  dim3 threads, blocks;
  ComputeKernelParamsForImage(blocks,threads,d,32,32);
  //std::cout << blocks.x << " " << blocks.y << " " << blocks.z << std::endl;
  KernelDepth2PC<<<blocks,threads>>>(d,cam,pc);
  checkCudaErrors(cudaDeviceSynchronize());
}

}
