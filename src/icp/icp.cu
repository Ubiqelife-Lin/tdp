/* Copyright (c) 2016, Julian Straub <jstraub@csail.mit.edu> Licensed
 * under the MIT license. See the license file LICENSE.
 */

#include <assert.h>
#include <tdp/eigen/dense.h>
#include <tdp/cuda/cuda.h>
#include <tdp/nvidia/helper_cuda.h>
#include <tdp/data/image.h>
#include <tdp/data/managed_image.h>
#include <tdp/camera/camera.h>
#include <tdp/camera/camera_poly.h>
#include <tdp/reductions/reductions.cuh>
#include <tdp/manifold/SE3.h>
#include <tdp/cuda/cuda.cuh>

namespace tdp {

template<int D, class Derived>
__device__ 
inline int AssociateModelIntoCurrent(
    int x, int y, 
    const Image<Vector3fda>& pc_m,
    const SE3f& T_mo,
    const SE3f& T_co,
    const CameraBase<float,D,Derived>& cam,
    int& u, int& v
    ) {
  // project model point into camera frame to get association
  if (x < pc_m.w_ && y < pc_m.h_ ) {
    Vector3fda pc_mi = pc_m(x,y);
    if (IsValidData(pc_mi)) {
      Vector3fda pc_m_in_o = T_mo.Inverse() * pc_mi;
      // project into current camera
      Vector2fda x_m_in_o = cam.Project(T_co*pc_m_in_o);
      u = floor(x_m_in_o(0)+0.5f);
      v = floor(x_m_in_o(1)+0.5f);
      if (0 <= u && u < pc_m.w_ && 0 <= v && v < pc_m.h_
          && pc_m_in_o(2) > 0.
          && IsValidData(pc_m_in_o)) {
        return 0;
      } else {
        return 1;
      }
    } else {
      return 2;
    }
  } else {
    return 3;
  }
}


// T_mc: R_model_observation
template<int BLK_SIZE>
__global__ void KernelICPStep(
    Image<Vector3fda> pc_m,
    Image<Vector3fda> n_m,
    Image<Vector3fda> pc_o,
    Image<Vector3fda> n_o,
    Image<int> assoc_om,
    SE3f T_mo, 
    float dotThr,
    float distThr,
    int N_PER_T,
    Image<float> out
    ) {
  assert(BLK_SIZE >=29);
  const int tid = threadIdx.x;
  const int idx = threadIdx.x + blockDim.x * blockIdx.x;
  const int idS = idx*N_PER_T;
  const int N = pc_m.w_*pc_m.h_;
  const int idE = min(N,(idx+1)*N_PER_T);

  SharedMemory<Vector29fda> smem;
  Vector29fda* sum = smem.getPointer();

  sum[tid] = Vector29fda::Zero();
  for (int id=idS; id<idE; ++id) {
    const int x = id%pc_m.w_;
    const int y = id/pc_m.w_;
    if (x<pc_m.w_ && y<pc_m.h_) {
      const int id_o = assoc_om(x,y);
      const int u = id_o%pc_o.w_;
      const int v = id_o/pc_o.w_;
      if (0<=u && u<pc_o.w_ && 0<=v && v<pc_o.h_) {
        // found association -> check thresholds;
        Vector3fda n_o_in_m = T_mo.rotation()*n_o(u,v);
        Vector3fda n_mi = n_m(x,y);
        Vector3fda pc_mi = pc_m(x,y);
        Vector3fda pc_oi = pc_o(u,v);
        Vector3fda pc_o_in_m = T_mo * pc_oi;
        const float dot  = n_mi.dot(n_o_in_m);
        const float dist = (pc_mi-pc_o_in_m).norm();
        if (dot > dotThr && dist < distThr && IsValidData(pc_mi)) {
          // association is good -> accumulate
          // if we found a valid association accumulate the A and b for A x = b
          // where x \in se{3} as well as the residual error
          float ab[7];      
          Eigen::Map<Vector3fda> top(&(ab[0]));
          Eigen::Map<Vector3fda> bottom(&(ab[3]));
          // as in mp3guy: 
          top = (pc_o_in_m).cross(n_mi);
          bottom = n_mi;
          ab[6] = n_mi.dot(pc_mi-pc_o_in_m);
          Eigen::Matrix<float,29,1,Eigen::DontAlign> upperTriangle;
          int k=0;
#pragma unroll
          for (int i=0; i<7; ++i) {
            for (int j=i; j<7; ++j) {
              upperTriangle(k++) = ab[i]*ab[j];
            }
          }
          upperTriangle(28) = 1.; // to get number of data points
          sum[tid] += upperTriangle;
        }
      }
    }
  }
  __syncthreads(); //sync the threads
#pragma unroll
  for(int s=(BLK_SIZE)/2; s>1; s>>=1) {
    if(tid < s) {
      sum[tid] += sum[tid+s];
    }
    __syncthreads();
  }
  if(tid < 29) {
    // sum the last two remaining matrixes directly into global memory
    atomicAdd(&out[tid], sum[0](tid)+sum[1](tid));
  }
}

void ICPStep (
    Image<Vector3fda> pc_m,
    Image<Vector3fda> n_m,
    Image<Vector3fda> pc_o,
    Image<Vector3fda> n_o,
    Image<int> assoc_om,
    const SE3f& T_mo, 
    float dotThr,
    float distThr,
    Eigen::Matrix<float,6,6,Eigen::DontAlign>& ATA,
    Eigen::Matrix<float,6,1,Eigen::DontAlign>& ATb,
    float& error,
    float& count
    ) {
  const size_t BLK_SIZE = 32;
  size_t N = pc_m.w_*pc_m.h_;
  dim3 threads, blocks;
  ComputeKernelParamsForArray(blocks,threads,N/10,BLK_SIZE);
  ManagedDeviceImage<float> out(29,1);
  cudaMemset(out.ptr_, 0, 29*sizeof(float));

  KernelICPStep<BLK_SIZE><<<blocks,threads,
    BLK_SIZE*sizeof(Vector29fda)>>>(
        pc_m,n_m,pc_o,n_o,assoc_om,T_mo,dotThr,distThr,10,out);
  checkCudaErrors(cudaDeviceSynchronize());
  ManagedHostImage<float> sumAb(29,1);
  cudaMemcpy(sumAb.ptr_,out.ptr_,29*sizeof(float), cudaMemcpyDeviceToHost);

  //for (int i=0; i<29; ++i) std::cout << sumAb[i] << "\t";
  //std::cout << std::endl;
  ATA.fill(0.);
  ATb.fill(0.);
  int k = 0;
  for (int i=0; i<6; ++i) {
    for (int j=i; j<7; ++j) {
      float val = sumAb[k++];
      if (j==6)  {
        ATb(i) = val;
      } else {
        ATA(i,j) = val;
        ATA(j,i) = val;
      }
    }
  }
  count = sumAb[28];
  error = sumAb[27]/count;
  //std::cout << ATA << std::endl << ATb.transpose() << std::endl;
  //std::cout << "\terror&count " << error << " " << count << std::endl;
}

// T_mc: R_model_observation
template<int BLK_SIZE, int D, typename Derived>
__global__ void KernelICPStep(
    Image<Vector3fda> pc_m,
    Image<Vector3fda> n_m,
    Image<Vector3fda> pc_o,
    Image<Vector3fda> n_o,
    SE3f T_mo, 
    SE3f T_co, 
    const CameraBase<float,D,Derived> cam,
    float dotThr,
    float distThr,
    int N_PER_T,
    Image<float> out
    ) {
  assert(BLK_SIZE >=29);
  const int tid = threadIdx.x;
  const int idx = threadIdx.x + blockDim.x * blockIdx.x;
  const int idS = idx*N_PER_T;
  const int N = pc_m.w_*pc_m.h_;
  const int idE = min(N,(idx+1)*N_PER_T);

  SharedMemory<Vector29fda> smem;
  Vector29fda* sum = smem.getPointer();

  sum[tid] = Vector29fda::Zero();
  for (int id=idS; id<idE; ++id) {
    const int x = id%pc_o.w_;
    const int y = id/pc_o.w_;
    int u, v;
    int res = AssociateModelIntoCurrent<D,Derived>(x, y, pc_m, T_mo,
        T_co, cam, u, v);
    if (res == 0) {
      // found association -> check thresholds;
      Vector3fda n_o_in_m = T_mo.rotation()*n_o(u,v);
      Vector3fda n_mi = n_m(x,y);
      Vector3fda pc_mi = pc_m(x,y);
      Vector3fda pc_oi = pc_o(u,v);
      Vector3fda pc_o_in_m = T_mo * pc_oi;
      const float dot  = n_mi.dot(n_o_in_m);
      const float dist = (pc_mi-pc_o_in_m).norm();
      if (dot > dotThr && dist < distThr && IsValidData(pc_mi)) {
        // association is good -> accumulate
        // if we found a valid association accumulate the A and b for A x = b
        // where x \in se{3} as well as the residual error
        float ab[7];      
        Eigen::Map<Vector3fda> top(&(ab[0]));
        Eigen::Map<Vector3fda> bottom(&(ab[3]));
        // as in mp3guy: 
        top = (pc_o_in_m).cross(n_mi);
        bottom = n_mi;
        ab[6] = n_mi.dot(pc_mi-pc_o_in_m);
        Eigen::Matrix<float,29,1,Eigen::DontAlign> upperTriangle;
        int k=0;
#pragma unroll
        for (int i=0; i<7; ++i) {
          for (int j=i; j<7; ++j) {
            upperTriangle(k++) = ab[i]*ab[j];
          }
        }
        upperTriangle(28) = 1.; // to get number of data points
        sum[tid] += upperTriangle;
      }
    }
  }
  __syncthreads(); //sync the threads
#pragma unroll
  for(int s=(BLK_SIZE)/2; s>1; s>>=1) {
    if(tid < s) {
      sum[tid] += sum[tid+s];
    }
    __syncthreads();
  }
  if(tid < 29) {
    // sum the last two remaining matrixes directly into global memory
    atomicAdd(&out[tid], sum[0](tid)+sum[1](tid));
  }
}

template<int D, typename Derived>
void ICPStep (
    Image<Vector3fda> pc_m,
    Image<Vector3fda> n_m,
    Image<Vector3fda> pc_o,
    Image<Vector3fda> n_o,
    const SE3f& T_mo, 
    const SE3f& T_cm,
    const CameraBase<float,D,Derived>& cam,
    float dotThr,
    float distThr,
    Eigen::Matrix<float,6,6,Eigen::DontAlign>& ATA,
    Eigen::Matrix<float,6,1,Eigen::DontAlign>& ATb,
    float& error,
    float& count
    ) {
  const size_t BLK_SIZE = 32;
  size_t N = pc_m.w_*pc_m.h_;
  dim3 threads, blocks;
  ComputeKernelParamsForArray(blocks,threads,N/10,BLK_SIZE);
  ManagedDeviceImage<float> out(29,1);
  cudaMemset(out.ptr_, 0, 29*sizeof(float));

  KernelICPStep<BLK_SIZE,D,Derived><<<blocks,threads,
    BLK_SIZE*sizeof(Vector29fda)>>>(
        pc_m,n_m,pc_o,n_o,T_mo,T_cm,cam,
        dotThr,distThr,10,out);
  checkCudaErrors(cudaDeviceSynchronize());
  ManagedHostImage<float> sumAb(29,1);
  cudaMemcpy(sumAb.ptr_,out.ptr_,29*sizeof(float), cudaMemcpyDeviceToHost);

  //for (int i=0; i<29; ++i) std::cout << sumAb[i] << "\t";
  //std::cout << std::endl;
  ATA.fill(0.);
  ATb.fill(0.);
  int k = 0;
  for (int i=0; i<6; ++i) {
    for (int j=i; j<7; ++j) {
      float val = sumAb[k++];
      if (j==6)  {
        ATb(i) = val;
      } else {
        ATA(i,j) = val;
        ATA(j,i) = val;
      }
    }
  }
  count = sumAb[28];
  error = sumAb[27]/count;
  //std::cout << ATA << std::endl << ATb.transpose() << std::endl;
  //std::cout << "\terror&count " << error << " " << count << std::endl;
}

// explicit instantiation
template void ICPStep (
    Image<Vector3fda> pc_m, Image<Vector3fda> n_m, Image<Vector3fda> pc_o,
    Image<Vector3fda> n_o, const SE3f& T_mo, const SE3f& T_cm,
    const CameraBase<float,Camera<float>::NumParams,Camera<float>>& cam,
    float dotThr, float distThr, Eigen::Matrix<float,6,6,Eigen::DontAlign>& ATA,
    Eigen::Matrix<float,6,1,Eigen::DontAlign>& ATb, float& error, float& count);
template void ICPStep (
    Image<Vector3fda> pc_m, Image<Vector3fda> n_m, Image<Vector3fda> pc_o,
    Image<Vector3fda> n_o, const SE3f& T_mo, const SE3f& T_cm,
    const CameraBase<float,CameraPoly3<float>::NumParams,CameraPoly3<float>>& cam,
    float dotThr, float distThr, Eigen::Matrix<float,6,6,Eigen::DontAlign>& ATA,
    Eigen::Matrix<float,6,1,Eigen::DontAlign>& ATb, float& error, float& count);

// T_mc: R_model_observation
template<int BLK_SIZE, int D, typename Derived>
__global__ void KernelICPStep(
    Image<Vector3fda> pc_m,
    Image<Vector3fda> n_m,
    Image<Vector3fda> g_m,
    Image<Vector3fda> pc_o,
    Image<Vector3fda> n_o,
    Image<Vector3fda> g_o,
    SE3f T_mo, 
    SE3f T_co, 
    const CameraBase<float,D,Derived> cam,
    float dotThr,
    float distThr,
    int N_PER_T,
    Image<float> out
    ) {
  assert(BLK_SIZE >=29);
  const int tid = threadIdx.x;
  const int idx = threadIdx.x + blockDim.x * blockIdx.x;
  const int idS = idx*N_PER_T;
  const int N = pc_m.w_*pc_m.h_;
  const int idE = min(N,(idx+1)*N_PER_T);

  SharedMemory<Vector29fda> smem;
  Vector29fda* sum = smem.getPointer();

  sum[tid] = Vector29fda::Zero();
  for (int id=idS; id<idE; ++id) {
    const int x = id%pc_o.w_;
    const int y = id/pc_o.w_;
    int u, v;
    int res = AssociateModelIntoCurrent<D,Derived>(x, y, pc_m, T_mo,
        T_co, cam, u, v);
    if (res == 0) {
      // found association -> check thresholds;
      Vector3fda n_o_in_m = T_mo.rotation()*n_o(u,v);
      Vector3fda n_mi = n_m(x,y);
      Vector3fda g_mi = g_m(x,y).normalized();
      Vector3fda pc_mi = pc_m(x,y);
      Vector3fda pc_oi = pc_o(u,v);
      Vector3fda pc_o_in_m = T_mo * pc_oi;
      const float dot  = n_mi.dot(n_o_in_m);
      const float dist = (pc_mi-pc_o_in_m).norm();
      if (dot > dotThr && dist < distThr && IsValidData(pc_mi)) {
        // association is good -> accumulate
        // if we found a valid association accumulate the A and b for A x = b
        // where x \in se{3} as well as the residual error
        
        // contribution by surface normal
        float ab[7];      
        Eigen::Map<Vector3fda> top(&(ab[0]));
        Eigen::Map<Vector3fda> bottom(&(ab[3]));
        // as in mp3guy: 
        top = (pc_o_in_m).cross(n_mi);
        bottom = n_mi;
        ab[6] = n_mi.dot(pc_mi-pc_o_in_m);

        // contribution by 3D gradients
        float abg[7];      
        Eigen::Map<Vector3fda> topg(&(abg[0]));
        Eigen::Map<Vector3fda> bottomg(&(abg[3]));
        if (IsValidData(g_mi)) {
            topg = (pc_o_in_m).cross(g_mi);
            bottomg = g_mi;
            abg[6] = g_mi.dot(pc_mi-pc_o_in_m);
        } else {
          topg = Vector3fda::Zero(); 
          bottomg = Vector3fda::Zero(); 
          abg[6] = 0.;
        }

        Eigen::Matrix<float,29,1,Eigen::DontAlign> upperTriangle;
        int k=0;
#pragma unroll
        for (int i=0; i<7; ++i) {
          for (int j=i; j<7; ++j) {
            upperTriangle(k++) = ab[i]*ab[j] + abg[i]*abg[j];
          }
        }
        upperTriangle(28) = 1.; // to get number of data points
        sum[tid] += upperTriangle;
      }
    }
  }
  __syncthreads(); //sync the threads
#pragma unroll
  for(int s=(BLK_SIZE)/2; s>1; s>>=1) {
    if(tid < s) {
      sum[tid] += sum[tid+s];
    }
    __syncthreads();
  }
  if(tid < 29) {
    // sum the last two remaining matrixes directly into global memory
    atomicAdd(&out[tid], sum[0](tid)+sum[1](tid));
  }
}

template<int D, typename Derived>
void ICPStep (
    Image<Vector3fda> pc_m,
    Image<Vector3fda> n_m,
    Image<Vector3fda> g_m,
    Image<Vector3fda> pc_o,
    Image<Vector3fda> n_o,
    Image<Vector3fda> g_o,
    const SE3f& T_mo, 
    const SE3f& T_cm,
    const CameraBase<float,D,Derived>& cam,
    float dotThr,
    float distThr,
    Eigen::Matrix<float,6,6,Eigen::DontAlign>& ATA,
    Eigen::Matrix<float,6,1,Eigen::DontAlign>& ATb,
    float& error,
    float& count
    ) {
  const size_t BLK_SIZE = 32;
  size_t N = pc_m.w_*pc_m.h_;
  dim3 threads, blocks;
  ComputeKernelParamsForArray(blocks,threads,N/10,BLK_SIZE);
  ManagedDeviceImage<float> out(29,1);
  cudaMemset(out.ptr_, 0, 29*sizeof(float));

  KernelICPStep<BLK_SIZE,D,Derived><<<blocks,threads,
    BLK_SIZE*sizeof(Vector29fda)>>>(
        pc_m,n_m,g_m,pc_o,n_o,g_o,T_mo,T_cm,cam,
        dotThr,distThr,10,out);
  checkCudaErrors(cudaDeviceSynchronize());
  ManagedHostImage<float> sumAb(29,1);
  cudaMemcpy(sumAb.ptr_,out.ptr_,29*sizeof(float), cudaMemcpyDeviceToHost);

  //for (int i=0; i<29; ++i) std::cout << sumAb[i] << "\t";
  //std::cout << std::endl;
  ATA.fill(0.);
  ATb.fill(0.);
  int k = 0;
  for (int i=0; i<6; ++i) {
    for (int j=i; j<7; ++j) {
      float val = sumAb[k++];
      if (j==6)  {
        ATb(i) = val;
      } else {
        ATA(i,j) = val;
        ATA(j,i) = val;
      }
    }
  }
  count = sumAb[28];
  error = sumAb[27]/count;
  //std::cout << ATA << std::endl << ATb.transpose() << std::endl;
  //std::cout << "\terror&count " << error << " " << count << std::endl;
}

// explicit instantiation
template void ICPStep (
    Image<Vector3fda> pc_m, Image<Vector3fda> n_m, Image<Vector3fda> g_m, 
    Image<Vector3fda> pc_o, Image<Vector3fda> n_o, Image<Vector3fda> g_o,
    const SE3f& T_mo, const SE3f& T_cm,
    const CameraBase<float,Camera<float>::NumParams,Camera<float>>& cam,
    float dotThr, float distThr, Eigen::Matrix<float,6,6,Eigen::DontAlign>& ATA,
    Eigen::Matrix<float,6,1,Eigen::DontAlign>& ATb, float& error, float& count);
template void ICPStep (
    Image<Vector3fda> pc_m, Image<Vector3fda> n_m, Image<Vector3fda> g_m, 
    Image<Vector3fda> pc_o, Image<Vector3fda> n_o, Image<Vector3fda> g_o,
    const SE3f& T_mo, const SE3f& T_cm,
    const CameraBase<float,CameraPoly3<float>::NumParams,CameraPoly3<float>>& cam,
    float dotThr, float distThr, Eigen::Matrix<float,6,6,Eigen::DontAlign>& ATA,
    Eigen::Matrix<float,6,1,Eigen::DontAlign>& ATb, float& error, float& count);

// T_mc: R_model_observation
template<int BLK_SIZE, int D, class Derived>
__global__ void KernelICPVisualizeAssoc(
    Image<Vector3fda> pc_m,
    Image<Vector3fda> n_m,
    Image<Vector3fda> pc_o,
    Image<Vector3fda> n_o,
    SE3f T_mo,
    const CameraBase<float,D,Derived> cam,
    float dotThr,
    float distThr,
    int N_PER_T,
    Image<float> assoc_m,
    Image<float> assoc_o
    ) {
  const int idx = threadIdx.x + blockDim.x * blockIdx.x;
  const int idS = idx*N_PER_T;
  const int N = pc_m.w_*pc_m.h_;
  const int idE = min(N,(idx+1)*N_PER_T);

  for (int id=idS; id<idE; ++id) {
    const int x = id%pc_m.w_;
    const int y = id/pc_m.w_;
    int u, v;
    int res = AssociateModelIntoCurrent<D,Derived>(x, y, pc_m, T_mo,
        tdp::SE3f(), cam, u, v);
    if (res == 0) {
      // found association -> check thresholds;
      Vector3fda pc_mi = pc_m(x,y);
      Vector3fda n_mi = n_m(x,y);
      Vector3fda n_o_in_m = T_mo.rotation() * n_o(u,v);
      Vector3fda pc_oi = pc_o(u,v);
      Vector3fda pc_o_in_m = T_mo * pc_oi;
      float dot  = n_mi.dot(n_o_in_m);
      float dist = (pc_mi-pc_o_in_m).norm();
      if (dot > dotThr && dist < distThr && IsValidData(pc_mi)) {
        // association is good -> accumulate
        //assoc_m(u,v) = n_mi.dot(-pc_mi+pc_o_in_m);
        //assoc_o(x,y) = n_mi.dot(-pc_mi+pc_o_in_m);
        assoc_m(x,y) = n_mi.dot(-pc_mi+pc_o_in_m);
        //        assoc_o(u,v) = n_mi.dot(-pc_mi+pc_o_in_m);
        //          if (threadIdx.x < 3) printf("%d,%d and %d,%d\n", x,y,u,v);
      }
    } else if (res < 3) {
      assoc_o(x,y) = res;
    }
  }
}

template<int D, typename Derived>
void ICPVisualizeAssoc (
    Image<Vector3fda> pc_m,
    Image<Vector3fda> n_m,
    Image<Vector3fda> pc_o,
    Image<Vector3fda> n_o,
    const SE3f& T_mo,
    const CameraBase<float,D,Derived>& cam,
    float angleThr,
    float distThr,
    Image<float>& assoc_m,
    Image<float>& assoc_o
    ) {
  size_t N = pc_m.w_*pc_m.h_;
  dim3 threads, blocks;
  ComputeKernelParamsForArray(blocks,threads,N/10,256);
  KernelICPVisualizeAssoc<256,D,Derived><<<blocks,threads>>>(pc_m,n_m,pc_o,n_o,
      T_mo,cam, cos(angleThr*M_PI/180.),distThr,10,assoc_m, assoc_o);
  checkCudaErrors(cudaDeviceSynchronize());
}

template void ICPVisualizeAssoc (
    Image<Vector3fda> pc_m, Image<Vector3fda> n_m, Image<Vector3fda> pc_o,
    Image<Vector3fda> n_o, const SE3f& T_mo,
    const CameraBase<float,Camera<float>::NumParams,Camera<float>>& cam,
    float angleThr, float distThr, Image<float>& assoc_m, Image<float>& assoc_o);
template void ICPVisualizeAssoc (
    Image<Vector3fda> pc_m, Image<Vector3fda> n_m, Image<Vector3fda> pc_o,
    Image<Vector3fda> n_o, const SE3f& T_mo,
    const CameraBase<float,CameraPoly3<float>::NumParams,CameraPoly3<float>>& cam,
    float angleThr, float distThr, Image<float>& assoc_m, Image<float>& assoc_o);

// T_mc: T_model_current
template<int BLK_SIZE, int D, typename Derived>
__global__ void KernelICPStepRotation(
    Image<Vector3fda> n_m,
    Image<Vector3fda> n_o,
    Image<Vector3fda> pc_o,
    SE3f T_mo, 
    const CameraBase<float,D,Derived> cam,
    float dotThr,
    int N_PER_T,
    Image<float> out
    ) {
  assert(BLK_SIZE >=10);
  const int tid = threadIdx.x;
  const int id_ = threadIdx.x + blockDim.x * blockIdx.x;
  const int idS = id_*N_PER_T;
  const int idE = min((int)pc_o.Area(),(id_+1)*N_PER_T);
  SharedMemory<Vector10fda> smem;
  Vector10fda* sum = smem.getPointer();
  sum[tid] = Vector10fda::Zero();
  for (int id=idS; id<idE; ++id) {
    const int idx = id%pc_o.w_;
    const int idy = id/pc_o.w_;
    // project current point into model frame to get association
    if (idx >= pc_o.w_ || idy >= pc_o.h_) continue;
    Vector3fda pc_oi = pc_o(idx,idy);
    Vector3fda pc_o_in_m = T_mo * pc_oi ;
    // project into model camera
    // TODO: doing the association the other way around might be more
    // stable since the model depth is smoothed
    Vector2fda x_o_in_m = cam.Project(pc_o_in_m);
    const int u = floor(x_o_in_m(0)+0.5f);
    const int v = floor(x_o_in_m(1)+0.5f);
    if (0 <= u && u < pc_o.w_ && 0 <= v && v < pc_o.h_
        && pc_oi(2) > 0. && pc_o_in_m(2) > 0.
        && IsValidData(pc_o_in_m)) {
      // found association -> check thresholds;
      Vector3fda n_o_in_m = T_mo.rotation() * n_o(idx,idy);
//      Vector3fda n_o_in_m = n_o(idx,idy);
      Vector3fda n_mi = n_m(u,v);
      const float dot  = n_mi.dot(n_o_in_m);
      if (dot > dotThr && IsValidData(n_mi)) {
        // association is good -> accumulate
        sum[tid](0) += n_mi(0)*n_o_in_m(0);
        sum[tid](1) += n_mi(0)*n_o_in_m(1);
        sum[tid](2) += n_mi(0)*n_o_in_m(2);
        sum[tid](3) += n_mi(1)*n_o_in_m(0);
        sum[tid](4) += n_mi(1)*n_o_in_m(1);
        sum[tid](5) += n_mi(1)*n_o_in_m(2);
        sum[tid](6) += n_mi(2)*n_o_in_m(0);
        sum[tid](7) += n_mi(2)*n_o_in_m(1);
        sum[tid](8) += n_mi(2)*n_o_in_m(2);
        sum[tid](9) += 1.; // to get number of data points
      }
    }
  }
  __syncthreads(); //sync the threads
#pragma unroll
  for(int s=(BLK_SIZE)/2; s>1; s>>=1) {
    if(tid < s) {
      sum[tid] += sum[tid+s];
    }
    __syncthreads();
  }
  if(tid < 10) {
    // sum the last two remaining matrixes directly into global memory
    atomicAdd(&out[tid], sum[0](tid)+sum[1](tid));
  }
}

template<int D, typename Derived>
void ICPStepRotation (
    Image<Vector3fda> n_m,
    Image<Vector3fda> n_o,
    Image<Vector3fda> pc_o,
    const SE3f& T_mo, 
    const CameraBase<float,D,Derived>& cam,
    float dotThr,
    Eigen::Matrix<float,3,3,Eigen::DontAlign>& N,
    float& count
    ) {
  const size_t BLK_SIZE = 32;
  dim3 threads, blocks;
  ComputeKernelParamsForArray(blocks,threads,pc_o.Area()/10,BLK_SIZE);
  ManagedDeviceImage<float> out(10,1);
  cudaMemset(out.ptr_, 0, 10*sizeof(float));

  KernelICPStepRotation<BLK_SIZE,D,Derived><<<blocks,threads,
    BLK_SIZE*sizeof(Vector10fda)>>>(
        n_m,n_o,pc_o,T_mo,cam,
        dotThr,10,out);
  checkCudaErrors(cudaDeviceSynchronize());
  ManagedHostImage<float> nUpperTri(10,1);
  cudaMemcpy(nUpperTri.ptr_,out.ptr_,10*sizeof(float), cudaMemcpyDeviceToHost);

  //for (int i=0; i<29; ++i) std::cout << sumAb[i] << "\t";
  //std::cout << std::endl;
  N.fill(0.);
  int k = 0;
  for (int i=0; i<3; ++i) {
    for (int j=0; j<3; ++j) {
      N(i,j) = nUpperTri[k++];
    }
  }
  count = nUpperTri[9];
  //std::cout << ATA << std::endl << ATb.transpose() << std::endl;
  //std::cout << "\terror&count " << error << " " << count << std::endl;
}

template void ICPStepRotation (
    Image<Vector3fda> n_m,
    Image<Vector3fda> n_o,
    Image<Vector3fda> pc_o,
    const SE3f& T_mo, 
    const BaseCameraf& cam,
    float dotThr,
    Eigen::Matrix<float,3,3,Eigen::DontAlign>& N,
    float& count);
template void ICPStepRotation (
    Image<Vector3fda> n_m,
    Image<Vector3fda> n_o,
    Image<Vector3fda> pc_o,
    const SE3f& T_mo, 
    const BaseCameraPoly3f& cam,
    float dotThr,
    Eigen::Matrix<float,3,3,Eigen::DontAlign>& N,
    float& count);

}
