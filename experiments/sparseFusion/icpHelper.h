/* Copyright (c) 2017, Julian Straub <jstraub@csail.mit.edu> Licensed
 * under the MIT license. See the license file LICENSE.
 */
#pragma once
#include <tdp/data/image.h>
#include <tdp/data/circular_buffer.h>
#include <tdp/manifold/SE3.h>
#include <tdp/eigen/dense.h>
#include <tdp/preproc/plane.h>
#include <tdp/camera/camera_base.h>
#include <tdp/features/brief.h>

namespace tdp {

bool EnsureNormal(
    Image<Vector3fda>& pc,
    Image<Vector4fda>& dpc,
    uint32_t W,
    Image<Vector3fda>& n,
    Image<float>& curv,
    int32_t u,
    int32_t v);


template<int D, typename Derived>
bool ProjectiveAssoc(const Plane& pl, 
    tdp::SE3f& T_cw, 
    CameraBase<float,D,Derived>& cam,
    const Image<Vector3fda>& pc,
    int32_t& u,
    int32_t& v
    ) {
  const tdp::Vector3fda& pc_w = pl.p_;
  Eigen::Vector2f x = cam.Project(T_cw*pc_w);
  u = floor(x(0)+0.5f);
  v = floor(x(1)+0.5f);
  if (0 <= u && u < pc.w_ && 0 <= v && v < pc.h_) {
    if (tdp::IsValidData(pc(u,v))) {
      return true;
    }
  }
  return false;
}

template<int D, typename Derived>
bool ProjectiveAssocNormalExtract(const Plane& pl, 
    tdp::SE3f& T_cw, 
    CameraBase<D,Derived>& cam,
    Image<Vector3fda>& pc,
    uint32_t W,
    Image<Vector4fda>& dpc,
    Image<Vector3fda>& n,
    Image<float>& curv,
    int32_t& u,
    int32_t& v
    ) {
  const tdp::Vector3fda& n_w =  pl.n_;
  const tdp::Vector3fda& pc_w = pl.p_;
  Eigen::Vector2f x = cam.Project(T_cw*pc_w);
  u = floor(x(0)+0.5f);
  v = floor(x(1)+0.5f);
  return EnsureNormal(pc, dpc, W, n, curv, u, v);
}

bool AccumulateP2Pl(const Plane& pl, 
    tdp::SE3f& T_wc, 
    tdp::SE3f& T_cw, 
    const Vector3fda& pc_ci,
    float distThr, 
    float p2plThr, 
    Eigen::Matrix<float,6,6>& A,
    Eigen::Matrix<float,6,1>& Ai,
    Eigen::Matrix<float,6,1>& b,
    float& err
    );

bool AccumulateP2Pl(const Plane& pl, 
    tdp::SE3f& T_wc, 
    tdp::SE3f& T_cw, 
    const Vector3fda& pc_ci,
    const Vector3fda& n_ci,
    float distThr, 
    float p2plThr, 
    float dotThr,
    Eigen::Matrix<float,6,6>& A,
    Eigen::Matrix<float,6,1>& Ai,
    Eigen::Matrix<float,6,1>& b,
    float& err
    );

/// uses texture as well
template<int D, typename Derived>
bool AccumulateP2Pl(const Plane& pl, 
    tdp::SE3f& T_wc, 
    tdp::SE3f& T_cw, 
    CameraBase<D,Derived>& cam,
    const Vector3fda& pc_ci,
    const Vector3fda& n_ci,
    float grey_ci,
    float distThr, 
    float p2plThr, 
    float dotThr,
    float lambda,
    Eigen::Matrix<float,6,6>& A,
    Eigen::Matrix<float,6,1>& Ai,
    Eigen::Matrix<float,6,1>& b,
    float& err
    ) {
  const tdp::Vector3fda& n_w =  pl.n_;
  const tdp::Vector3fda& pc_w = pl.p_;
  tdp::Vector3fda pc_c_in_w = T_wc*pc_ci;
  float bi=0;
  float dist = (pc_w - pc_c_in_w).norm();
  if (dist < distThr) {
    Eigen::Vector3f n_w_in_c = T_cw.rotation()*n_w;
    if (n_w_in_c.dot(n_ci) > dotThr) {
      float p2pl = n_w.dot(pc_w - pc_c_in_w);
      if (fabs(p2pl) < p2plThr) {
        // p2pl
        Ai.topRows<3>() = pc_ci.cross(n_w_in_c); 
        Ai.bottomRows<3>() = n_w_in_c; 
        bi = p2pl;
        A += Ai * Ai.transpose();
        b += Ai * bi;
        err += bi;
        // texture
        Eigen::Matrix<float,2,3> Jpi = cam.Jproject(pc_c_in_w);
        Eigen::Matrix<float,3,6> Jse3;
        Jse3 << -(T_wc.rotation().matrix()*SO3mat<float>::invVee(pc_ci)), 
             Eigen::Matrix3f::Identity();
        Ai = Jse3.transpose() * Jpi.transpose() * pl.gradGrey_;
        bi = grey_ci - pl.grey_;
        A += lambda*(Ai * Ai.transpose());
        b += lambda*(Ai * bi);
        err += lambda*bi;
        // accumulate
        return true;
      }
    }
  }
  return false;
}

/// uses texture and normal as well
template<int D, typename Derived>
bool AccumulateP2Pl(const Plane& pl, 
    tdp::SE3f& T_wc, 
    tdp::SE3f& T_cw, 
    CameraBase<D,Derived>& cam,
    const Vector3fda& pc_ci,
    const Vector3fda& n_ci,
    float grey_ci,
    float distThr, 
    float p2plThr, 
    float dotThr,
    float gamma,
    float lambda,
    Eigen::Matrix<float,6,6>& A,
    Eigen::Matrix<float,6,1>& Ai,
    Eigen::Matrix<float,6,1>& b,
    float& err
    ) {
  const tdp::Vector3fda& n_w =  pl.n_;
  const tdp::Vector3fda& pc_w = pl.p_;
  tdp::Vector3fda pc_c_in_w = T_wc*pc_ci;
  float bi=0;
  float dist = (pc_w - pc_c_in_w).norm();
  if (dist < distThr) {
    Eigen::Vector3f n_w_in_c = T_cw.rotation()*n_w;
    if (n_w_in_c.dot(n_ci) > dotThr) {
      float p2pl = n_w.dot(pc_w - pc_c_in_w);
      if (fabs(p2pl) < p2plThr) {
        // p2pl
        Ai.topRows<3>() = pc_ci.cross(n_w_in_c); 
        Ai.bottomRows<3>() = n_w_in_c; 
        bi = p2pl;
        A += Ai * Ai.transpose();
        b += Ai * bi;
        err += bi;
//        std::cout << "--" << std::endl;
//        std::cout << Ai.transpose() << "; " << bi << std::endl;
        // normal
        Ai.topRows<3>() = -n_ci.cross(n_w_in_c); 
        Ai.bottomRows<3>().fill(0.); 
        bi = n_ci.dot(n_w_in_c) - 1.;
        A += gamma*(Ai * Ai.transpose());
        b += gamma*(Ai * bi);
        err += gamma*bi;
//        std::cout << Ai.transpose() << "; " << bi << std::endl;
        // texture
        Eigen::Matrix<float,2,3> Jpi = cam.Jproject(pc_c_in_w);
        Eigen::Matrix<float,3,6> Jse3;
        Jse3 << -(T_wc.rotation().matrix()*SO3mat<float>::invVee(pc_ci)), 
             Eigen::Matrix3f::Identity();
        Ai = Jse3.transpose() * Jpi.transpose() * pl.gradGrey_;
        bi = grey_ci - pl.grey_;
        A += lambda*(Ai * Ai.transpose());
        b += lambda*(Ai * bi);
        err += lambda*bi;
//        std::cout << Ai.transpose() << "; " << bi << std::endl;
        // accumulate
        return true;
      }
    }
  }
  return false;
}

// uses texture and projective term
template<int D, typename Derived>
bool AccumulateP2PlProj(const Plane& pl, 
    tdp::SE3f& T_wc, 
    tdp::SE3f& T_cw, 
    CameraBase<D,Derived>& cam,
    const Image<Vector3fda>& pc_c,
    uint32_t u, uint32_t v,
    const Vector3fda& n_ci,
    float grey_ci,
    float distThr, 
    float p2plThr, 
    float dotThr,
    float lambda,
    Eigen::Matrix<float,6,6>& A,
    Eigen::Matrix<float,6,1>& Ai,
    Eigen::Matrix<float,6,1>& b,
    float& err
    ) {
  const tdp::Vector3fda& n_w =  pl.n_;
  const tdp::Vector3fda& pc_w = pl.p_;
  const tdp::Vector3fda& pc_ci = pc_c(u,v);
  tdp::Vector3fda pc_c_in_w = T_wc*pc_ci;
  float bi=0;
  float dist = (pc_w - pc_c_in_w).norm();
  if (dist < distThr) {
    Eigen::Vector3f n_w_in_c = T_cw.rotation()*n_w;
    if (n_w_in_c.dot(n_ci) > dotThr) {
      float p2pl = n_w.dot(pc_w - pc_c_in_w);
      if (fabs(p2pl) < p2plThr) {
        // p2pl projective term
        Eigen::Matrix<float,2,3> Jpi = cam.Jproject(pc_c_in_w);
        Eigen::Matrix<float,3,6> Jse3;
        Jse3 << -(T_wc.rotation().matrix()*SO3mat<float>::invVee(pc_ci)), 
             Eigen::Matrix3f::Identity();
        Eigen::Matrix<float,3,6> Jse3Inv;
        Jse3Inv << SO3mat<float>::invVee(T_wc.rotation().matrix().transpose()*(pc_w-T_wc.translation())), 
             -T_wc.rotation().matrix().transpose();
        
        std::cout << "--" << std::endl;
        // one delta u in image coords translates to delta x = z
//        Eigen::Matrix<float,3,1> tmp(0,0,0);
//        Eigen::Matrix<float,3,1> p_u(pc_ci(2)/cam.params_(0),0,0);
//        Eigen::Matrix<float,3,1> p_v(0,pc_ci(2)/cam.params_(1),0);
////        std::cout << p_u.transpose() << std::endl;
//        RejectAfromB(p_u, n_ci, tmp);
//        p_u = T_wc.rotation()*(tmp * pc_ci(2)/cam.params_(0) / tmp(0));
//        std::cout << tmp.transpose() <<  "; " << tmp.dot(n_ci) << std::endl;
////        std::cout << n_ci.transpose() << std::endl;
//        RejectAfromB(p_v, n_ci, tmp);
////        std::cout << p_u.transpose() << std::endl;
//        p_v = T_wc.rotation()*(tmp * pc_ci(2)/cam.params_(1) / tmp(1));
//        std::cout << tmp.transpose() <<  "; " << tmp.dot(n_ci) << std::endl;
        // could do better by exploiting robust computation if n (above)
        Eigen::Matrix<float,3,1> p_u = T_wc.rotation()*(pc_c(u+1,v) - pc_c(u,v));
        Eigen::Matrix<float,3,1> p_v = T_wc.rotation()*(pc_c(u,v+1) - pc_c(u,v));
        Eigen::Matrix<float,3,2> gradP;
        gradP << p_u, p_v;
        // p2pl projective
        Ai = Jse3Inv.transpose() * Jpi.transpose() * gradP.transpose() * n_w;
        std::cout << Ai.transpose() << std::endl;
//        std::cout << Jse3Inv << std::endl;
//        std::cout << Jpi << std::endl;
//        std::cout << gradP << std::endl;
//        std::cout << n_w.transpose() << std::endl;
//        std::cout << gradP.transpose()*n_w << std::endl;
//        std::cout << p_u.dot(p_v) << std::endl;
//        Ai.fill(0.);
        // p2pl
        Ai.topRows<3>() += pc_ci.cross(n_w_in_c); 
        Ai.bottomRows<3>() += n_w_in_c; 
        std::cout << Ai.transpose() << std::endl;
        bi = p2pl;
        A += Ai * Ai.transpose();
        b += Ai * bi;
        err += bi;
        // texture
        Ai = Jse3.transpose() * Jpi.transpose() * pl.gradGrey_;
        bi = grey_ci - pl.grey_;
        A += lambda*(Ai * Ai.transpose());
        b += lambda*(Ai * bi);
        err += lambda*bi;
        // accumulate
        return true;
      }
    }
  }
  return false;
}

bool AccumulateRot(const Plane& pl, 
    tdp::SE3f& T_wc, 
    tdp::SE3f& T_cw, 
    const Vector3fda& pc_ci,
    const Vector3fda& n_ci,
    float distThr, 
    float p2plThr, 
    float dotThr,
    Eigen::Matrix<float,3,3>& N
    );

bool CheckEntropyTermination(const Eigen::Matrix<float,6,6>& A,
    float Hprev,
    float HThr, float condEntropyThr, float negLogEvThr,
    float& H);

template<int D, typename Derived>
void IncrementalOpRot(
    const Image<Vector3fda>& pc, // in camera frame
    const Image<Vector3fda>& n,  // in camera frame
    const SE3f& T_wc,
    const CameraBase<float,D,Derived>& cam,
    float distThr, 
    float p2plThr, 
    float dotThr,
    uint32_t frame,
    Image<uint8_t> mask,
    CircularBuffer<tdp::Plane>& pl_w,
    CircularBuffer<tdp::Vector3fda> pc_c,
    CircularBuffer<tdp::Vector3fda> n_c,
    std::vector<std::pair<size_t, size_t>>& assoc,
    size_t& numProjected, 
    SO3f& R_wc
    ) {
  SE3f T_cw = T_wc.Inverse();
  Eigen::Matrix3f N = Eigen::Matrix3f::Zero();
  bool exploredAll = false;
  uint32_t K = invInd.size();
  uint32_t k = 0;
  while (!exploredAll) {
    k = (k+1)%(K+1);
    while (indK[k] < invInd[k].size()) {
      size_t i = invInd[k][indK[k]++];
      tdp::Plane& pl = pl_w.GetCircular(i);
      numProjected++;
      int32_t u, v;
      if (!tdp::ProjectiveAssocNormalExtract(pl, T_cw, cam, pc,
            W, dpc, n, curv, u,v ))
        continue;
      if (AccumulateRot(pl, T_wc, T_cw, pc(u,v), n(u,v),
            distThr, p2plThr, dotThr, N)) {
        pl.lastFrame_ = frame;
        pl.numObs_ ++;
        numInl ++;
        mask(u,v) ++;
        assoc.emplace_back(i,pc_c.SizeToRead());
        pc_c.Insert(pc(u,v));
        n_c.Insert(n(u,v));
        break;
      }
    }
    exploredAll = true;
    for (size_t k=0; k<indK.size(); ++k) 
      exploredAll &= indK[k] >= invInd[k].size();
  }
  R_wc = tdp::SO3f(tdp::ProjectOntoSO3<float>(N));
}

void IncrementalFullICP(
      Eigen::Matrix<float,6,6>&  A,
      Eigen::Matrix<float,6,1>&  b,
      Eigen::Matrix<float,6,1>& Ai,
    ) {



}



}