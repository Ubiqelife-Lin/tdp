/* Copyright (c) 2016, Julian Straub <jstraub@csail.mit.edu> Licensed
 * under the MIT license. See the license file LICENSE.
 */
#include <pangolin/pangolin.h>
#include <pangolin/video/video_record_repeat.h>
#include <pangolin/gl/gltexturecache.h>
#include <pangolin/gl/glpixformat.h>
#include <pangolin/handler/handler_image.h>
#include <pangolin/utils/file_utils.h>
#include <pangolin/utils/timer.h>
#include <pangolin/gl/gl.h>
#include <pangolin/gl/glsl.h>
#include <pangolin/gl/glvbo.h>
#include <pangolin/gl/gldraw.h>
#include <pangolin/image/image_io.h>

#include <tdp/eigen/dense.h>
#include <tdp/data/managed_image.h>

#include <tdp/preproc/depth.h>
#include <tdp/preproc/pc.h>
#include <tdp/camera/camera.h>
#include <tdp/gui/quickView.h>
#include <tdp/eigen/dense.h>
#include <tdp/utils/Stopwatch.h>
#ifdef CUDA_FOUND
#include <tdp/preproc/normals.h>
#endif

#include "gui.hpp"
#include <tdp/camera/rig.h>
#include <pangolin/video/drivers/openni2.h>

void VideoViewer(const std::string& input_uri, 
    const std::string& configPath,
    const std::string& output_uri)
{
  std::cout << " -!!- this application works only with openni2 devices (tested with Xtion PROs) -!!- " << std::endl;

  // Read rig file
  tdp::Rig<tdp::Cameraf> rig;
  if (!rig.FromFile(configPath, true)) return;

  // Open Video by URI
  pangolin::VideoRecordRepeat video(input_uri, output_uri);
  const size_t num_streams = video.Streams().size();

  if(num_streams == 0) {
    pango_print_error("No video streams from device.\n");
    return;
  }
  std::vector<pangolin::VideoInterface*>& streams = video.InputStreams();

  std::cout << streams.size() << " " << num_streams << std::endl;
  pangolin::OpenNiVideo2* openni = (pangolin::OpenNiVideo2*)streams[0];
  openni->UpdateProperties();
  pangolin::json::value devProps = openni->DeviceProperties();
  if (! devProps.contains("openni") ) return;
  pangolin::json::value jsDevices = devProps["openni"]["devices"];

  std::vector<int32_t> stream2cam;
  for (size_t i=0; i<jsDevices.size(); ++i) {
    std::string serial = jsDevices[i]["ONI_DEVICE_PROPERTY_SERIAL_NUMBER"].get<std::string>();
    std::cout << "Device " << i << " serial #: " << serial << std::endl;
    int32_t camId = -1;
    for (size_t j=0; j<rig.cams_.size(); ++j) {
      if (rig.serials_[j].compare(serial) == 0) {
        camId = j;
        break;
      }
    }
    if (camId < 0) {
      std::cerr << "no matching camera found in calibration!" << std::endl;
    } else {
      std::cout << "matching camera in config: " << camId 
        << " " << rig.config_[camId]["camera"]["description"].get<std::string>()
        << std::endl;
    }
    stream2cam.push_back(camId); // 
  }

  tdp::GUInoViews gui(1200,800,video);

  size_t wSingle = video.Streams()[0].Width();
  size_t hSingle = video.Streams()[0].Height();
  size_t w = wSingle;
  size_t h = 3*hSingle;
  // width and height need to be multiple of 64 for convolution
  // algorithm to compute normals.
  w += w%64;
  h += h%64;

  // Define Camera Render Object (for view / scene browsing)
  pangolin::OpenGlRenderState s_cam(
      pangolin::ProjectionMatrix(640,480,420,420,320,240,0.1,1000),
      pangolin::ModelViewLookAt(0,0.5,-3, 0,0,0, pangolin::AxisNegY)
      );
  // Add named OpenGL viewport to window and provide 3D Handler
  pangolin::View& d_cam = pangolin::CreateDisplay()
    .SetHandler(new pangolin::Handler3D(s_cam));
  gui.container().AddDisplay(d_cam);

  tdp::QuickView viewRgb(w,h);
  gui.container().AddDisplay(viewRgb);
  tdp::QuickView viewD(w,h);
  gui.container().AddDisplay(viewD);
  tdp::QuickView viewN2D(w,h);
  gui.container().AddDisplay(viewN2D);
  
  // host image: image in CPU memory
  tdp::ManagedHostImage<float> d(w, h);
  tdp::ManagedHostImage<tdp::Vector3fda> pc(w, h);
  tdp::ManagedHostImage<tdp::Vector3bda> rgb(w, h);
  tdp::ManagedHostImage<tdp::Vector3bda> n2D(w, h);

  // device image: image in GPU memory
  tdp::ManagedDeviceImage<uint16_t> cuDraw(w, h);
  tdp::ManagedDeviceImage<float> cuD(w, h);
  tdp::ManagedDeviceImage<tdp::Vector3fda> cuN(w, h);
  tdp::ManagedDeviceImage<tdp::Vector3bda> cuN2D(w, h);
  tdp::ManagedDeviceImage<tdp::Vector3fda> cuPc(w, h);

  pangolin::GlBuffer vbo(pangolin::GlArrayBuffer,w*h,GL_FLOAT,3);
  pangolin::GlBuffer cbo(pangolin::GlArrayBuffer,w*h,GL_UNSIGNED_BYTE,3);

  // Add some variables to GUI
  pangolin::Var<float> depthSensorScale("ui.depth sensor scale",1e-3,1e-4,1e-3);
  pangolin::Var<float> dMin("ui.d min",0.10,0.0,0.1);
  pangolin::Var<float> dMax("ui.d max",4.,0.1,4.);

  // Stream and display video
  while(!pangolin::ShouldQuit())
  {
    // clear the OpenGL render buffers
    glClear(GL_DEPTH_BUFFER_BIT | GL_COLOR_BUFFER_BIT);
    glColor3f(1.0f, 1.0f, 1.0f);
    // get next frames from the video source
    gui.NextFrames();

    TICK("rgb collection");
    // get rgb image
    for (size_t sId=0; sId < stream2cam.size(); sId++) {
      tdp::Image<tdp::Vector3bda> rgbStream;
      if (!gui.ImageRGB(rgbStream, sId)) continue;
      int32_t cId = stream2cam[sId]; 
      // Get ROI
      tdp::Image<tdp::Vector3bda> rgb_i(wSingle, hSingle,
          rgb.ptr_+cId*rgbStream.Area());
      rgb_i.CopyFrom(rgbStream,cudaMemcpyHostToHost);
    }
    TOCK("rgb collection");
    TICK("depth collection");
    // get depth image
    for (size_t sId=0; sId < stream2cam.size(); sId++) {
      tdp::Image<uint16_t> dStream;
      if (!gui.ImageD(dStream, sId)) continue;
      int32_t cId = stream2cam[sId]; 
      // Get ROI
      tdp::Image<uint16_t> d_i(wSingle, hSingle,
          cuDraw.ptr_+cId*dStream.Area());
      d_i.CopyFrom(dStream,cudaMemcpyHostToDevice);
    }
    TOCK("depth collection");
    TICK("pc and normals");
    // convert depth image from uint16_t to float [m]
    tdp::ConvertDepthGpu(cuDraw, cuD, depthSensorScale, dMin, dMax);
    // compute point cloud (on CPU)
    for (size_t sId=0; sId < stream2cam.size(); sId++) {
      int32_t cId = stream2cam[sId]; 
      tdp::Cameraf cam = rig.cams_[cId];
      tdp::SE3f T_rc = rig.T_rcs_[cId];

      tdp::Image<tdp::Vector3fda> cuN_i(wSingle, hSingle,
          cuN.ptr_+cId*wSingle*hSingle);
      tdp::Image<tdp::Vector3fda> cuPc_i(wSingle, hSingle,
          cuPc.ptr_+cId*wSingle*hSingle);
      tdp::Image<float> cuD_i(wSingle, hSingle,
          cuD.ptr_+cId*wSingle*hSingle);

      // compute depth
      tdp::Depth2PCGpu(cuD_i,cam,T_rc,cuPc_i);
      // compute normals
      tdp::Depth2Normals(cuD_i, cam, T_rc.rotation(), cuN_i);
    }
    TOCK("pc and normals");
    // convert normals to RGB image
    tdp::Normals2Image(cuN, cuN2D);
    // copy to CPU memory for vis
    d.CopyFrom(cuD, cudaMemcpyDeviceToHost);
    n2D.CopyFrom(cuN2D,cudaMemcpyDeviceToHost);
    pc.CopyFrom(cuPc,cudaMemcpyDeviceToHost);

    // Draw 3D stuff
    glEnable(GL_DEPTH_TEST);
    d_cam.Activate(s_cam);
    // draw the axis
    pangolin::glDrawAxis(0.1);
    vbo.Upload(pc.ptr_,pc.SizeBytes(), 0);
    cbo.Upload(rgb.ptr_,rgb.SizeBytes(), 0);
    // render point cloud
    pangolin::RenderVboCbo(vbo,cbo,true);

    glDisable(GL_DEPTH_TEST);
    // Draw 2D stuff
    viewRgb.SetImage(rgb);
    viewD.SetImage(d);
    viewN2D.SetImage(n2D);

    // leave in pixel orthographic for slider to render.
    pangolin::DisplayBase().ActivatePixelOrthographic();
    // if we are recording
    if(video.IsRecording()) {
      pangolin::glRecordGraphic(pangolin::DisplayBase().v.w-14.0f,
          pangolin::DisplayBase().v.h-14.0f, 7.0f);
    }
    // finish this frame
    Stopwatch::getInstance().sendAll();
    pangolin::FinishFrame();
  }
}


int main( int argc, char* argv[] )
{
  const std::string dflt_output_uri = "pango://video.pango";

  if( argc > 1 ) {
    const std::string input_uri = std::string(argv[1]);
    const std::string configPath = (argc > 2) ? std::string(argv[2]) : "../config/surround3D_2016_09_11.json";
    try{
      VideoViewer(input_uri, configPath, dflt_output_uri);
    } catch (pangolin::VideoException e) {
      std::cout << e.what() << std::endl;
    }
  }else{
    const std::string input_uris[] = {
      "dc1394:[fps=30,dma=10,size=640x480,iso=400]//0",
      "convert:[fmt=RGB24]//v4l:///dev/video0",
      "convert:[fmt=RGB24]//v4l:///dev/video1",
      "openni:[img1=rgb]//",
      "test:[size=160x120,n=1,fmt=RGB24]//"
        ""
    };

    std::cout << "Usage  : VideoViewer [video-uri]" << std::endl << std::endl;
    std::cout << "Where video-uri describes a stream or file resource, e.g." << std::endl;
    std::cout << "\tfile:[realtime=1]///home/user/video/movie.pvn" << std::endl;
    std::cout << "\tfile:///home/user/video/movie.avi" << std::endl;
    std::cout << "\tfiles:///home/user/seqiemce/foo%03d.jpeg" << std::endl;
    std::cout << "\tdc1394:[fmt=RGB24,size=640x480,fps=30,iso=400,dma=10]//0" << std::endl;
    std::cout << "\tdc1394:[fmt=FORMAT7_1,size=640x480,pos=2+2,iso=400,dma=10]//0" << std::endl;
    std::cout << "\tv4l:///dev/video0" << std::endl;
    std::cout << "\tconvert:[fmt=RGB24]//v4l:///dev/video0" << std::endl;
    std::cout << "\tmjpeg://http://127.0.0.1/?action=stream" << std::endl;
    std::cout << "\topenni:[img1=rgb]//" << std::endl;
    std::cout << std::endl;
  }

  return 0;
}