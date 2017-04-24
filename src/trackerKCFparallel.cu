#include "trackerKCFparallel.cpp"
#include <opencv2/cudaarithm.hpp>
#include "dft.cu"

/*---------------------------
|  TrackerKCFModel
|---------------------------*/
namespace cv{
   /**
  * \brief Implementation of TrackerModel for MIL algorithm
  */
  class TrackerKCFModel : public TrackerModel{
  public:
    TrackerKCFModel(TrackerKCF::Params /*params*/){}
    ~TrackerKCFModel(){}
  protected:
    void modelEstimationImpl( const std::vector<Mat>& /*responses*/ ){}
    void modelUpdateImpl(){}
  };
} /* namespace cv */

namespace cv {

    /*
    * Constructor
    */
     TackerKCFImplParallel::TackerKCFImplParallel( const TrackerKCF::Params &parameters ) :
         params( parameters )
     {
       isInit = false;
       resizeImage = false;
       use_custom_extractor_pca = false;
       use_custom_extractor_npca = false;
       #if TIME
       total_lines = num_steps;
       for (int i = 0; i < num_steps; i++) {
           cumulated_times[i] = 0;
       }
       #if TIME == 2
       for (int i = 0; i < num_steps - 1; i++) {
           total_lines += num_steps_details[i];
           for (int j = 0; j < max_num_details; j++) {
               cumulated_details_times[i][j] = 0;
           }
       }
       #endif
       #endif
     }

     void TackerKCFImplParallel::read( const cv::FileNode& fn ){
       params.read( fn );
     }

     void TackerKCFImplParallel::write( cv::FileStorage& fs ) const {
       params.write( fs );
     }

     /*
      * Initialization:
      * - creating hann window filter
      * - ROI padding
      * - creating a gaussian response for the training ground-truth
      * - perform FFT to the gaussian response
      */
     bool TackerKCFImplParallel::initImpl( const Mat& /*image*/, const Rect2d& boundingBox ){
       #if TIME
       double startInit = CycleTimer::currentSeconds();
       #endif

       frame=0;
       roi = boundingBox;

       //calclulate output sigma
       output_sigma=sqrt(roi.width*roi.height)*params.output_sigma_factor;
       output_sigma=-0.5/(output_sigma*output_sigma);

       //resize the ROI whenever needed
       if(params.resize && roi.width*roi.height>params.max_patch_size){
         resizeImage=true;
         roi.x/=2.0;
         roi.y/=2.0;
         roi.width/=2.0;
         roi.height/=2.0;
       }

       // add padding to the roi
       roi.x-=roi.width/2;
       roi.y-=roi.height/2;
       roi.width*=2;
       roi.height*=2;

       // initialize the hann window filter
       createHanningWindow(hann, roi.size(), CV_64F);

       // hann window filter for CN feature
       Mat _layer[] = {hann, hann, hann, hann, hann, hann, hann, hann, hann, hann};
       merge(_layer, 10, hann_cn);

       // create gaussian response
       y=Mat::zeros((int)roi.height,(int)roi.width,CV_64F);
       for(unsigned i=0;i<roi.height;i++){
         for(unsigned j=0;j<roi.width;j++){
           y.at<double>(i,j)=(i-roi.height/2+1)*(i-roi.height/2+1)+(j-roi.width/2+1)*(j-roi.width/2+1);
         }
       }

       y*=(double)output_sigma;
       cv::exp(y,y);

       // perform fourier transfor to the gaussian response
       fft2(y,yf);

       model=Ptr<TrackerKCFModel>(new TrackerKCFModel(params));

       // record the non-compressed descriptors
       if((params.desc_npca & GRAY) == GRAY)descriptors_npca.push_back(GRAY);
       if((params.desc_npca & CN) == CN)descriptors_npca.push_back(CN);
       if(use_custom_extractor_npca)descriptors_npca.push_back(CUSTOM);
       features_npca.resize(descriptors_npca.size());

       // record the compressed descriptors
       if((params.desc_pca & GRAY) == GRAY)descriptors_pca.push_back(GRAY);
       if((params.desc_pca & CN) == CN)descriptors_pca.push_back(CN);
       if(use_custom_extractor_pca)descriptors_pca.push_back(CUSTOM);
       features_pca.resize(descriptors_pca.size());

       // accept only the available descriptor modes
       CV_Assert(
         (params.desc_pca & GRAY) == GRAY
         || (params.desc_npca & GRAY) == GRAY
         || (params.desc_pca & CN) == CN
         || (params.desc_npca & CN) == CN
         || use_custom_extractor_pca
         || use_custom_extractor_npca
       );

       #if TIME
       printInitializationTime(startInit);
       #endif

       // TODO: return true only if roi inside the image
       return true;
     }

     /*
      * Main part of the KCF algorithm
      */
     bool TackerKCFImplParallel::updateImpl( const Mat& image, Rect2d& boundingBox ){
       #if TIME
       double startUpdate = CycleTimer::currentSeconds();
       #endif

       double minVal, maxVal;	// min-max response
       Point minLoc,maxLoc;	// min-max location

       Mat img=image.clone();
       // check the channels of the input image, grayscale is preferred
       CV_Assert(img.channels() == 1 || img.channels() == 3);

       // resize the image whenever needed
       if(resizeImage)resize(img,img,Size(img.cols/2,img.rows/2));

       #if TIME
       double startDetection = CycleTimer::currentSeconds();
       #endif

       // detection part
       if(frame>0){
         #if TIME == 2
         double startDetectionDetail = CycleTimer::currentSeconds();
         #endif

         // extract and pre-process the patch
         // get non compressed descriptors
         for(unsigned i=0;i<descriptors_npca.size()-extractor_npca.size();i++){
           if(!getSubWindow(img,roi, features_npca[i], img_Patch, descriptors_npca[i]))return false;
         }

         #if TIME == 2
         updateTimeDetail(&startDetectionDetail, 0, 0);
         #endif

         //get non-compressed custom descriptors
         for(unsigned i=0,j=(unsigned)(descriptors_npca.size()-extractor_npca.size());i<extractor_npca.size();i++,j++){
           if(!getSubWindow(img,roi, features_npca[j], extractor_npca[i]))return false;
         }
         if(features_npca.size()>0)merge(features_npca,X[1]);

         #if TIME == 2
         updateTimeDetail(&startDetectionDetail, 0, 1);
         #endif

         // get compressed descriptors
         for(unsigned i=0;i<descriptors_pca.size()-extractor_pca.size();i++){
           if(!getSubWindow(img,roi, features_pca[i], img_Patch, descriptors_pca[i]))return false;
         }


         #if TIME == 2
         updateTimeDetail(&startDetectionDetail, 0, 2);
         #endif

         //get compressed custom descriptors
         for(unsigned i=0,j=(unsigned)(descriptors_pca.size()-extractor_pca.size());i<extractor_pca.size();i++,j++){
           if(!getSubWindow(img,roi, features_pca[j], extractor_pca[i]))return false;
         }
         if(features_pca.size()>0)merge(features_pca,X[0]);

         #if TIME == 2
         updateTimeDetail(&startDetectionDetail, 0, 3);
         #endif

         //compress the features and the KRSL model
         if(params.desc_pca !=0){
           compress(proj_mtx,X[0],X[0],data_temp,compress_data);
           compress(proj_mtx,Z[0],Zc[0],data_temp,compress_data);
         }

         // copy the compressed KRLS model
         Zc[1] = Z[1];

         #if TIME == 2
         updateTimeDetail(&startDetectionDetail, 0, 4);
         #endif

         // merge all features
         if(features_npca.size()==0){
           x = X[0];
           z = Zc[0];
         }else if(features_pca.size()==0){
           x = X[1];
           z = Z[1];
         }else{
           merge(X,2,x);
           merge(Zc,2,z);
         }

         #if TIME == 2
         updateTimeDetail(&startDetectionDetail, 0, 5);
         #endif

         //compute the gaussian kernel
         denseGaussKernel(params.sigma,x,z,k,layers,vxf,vyf,vxyf,xy_data,xyf_data);

         #if TIME == 2
         updateTimeDetail(&startDetectionDetail, 0, 6);
         #endif

         // compute the fourier transform of the kernel
         fft2(k,kf);
         if(frame==1)spec2=Mat_<Vec2d >(kf.rows, kf.cols);

         #if TIME == 2
         updateTimeDetail(&startDetectionDetail, 0, 7);
         #endif

         // calculate filter response
         if(params.split_coeff)
           calcResponse(alphaf,alphaf_den,kf,response, spec, spec2);
         else
           calcResponse(alphaf,kf,response, spec);

         #if TIME == 2
         updateTimeDetail(&startDetectionDetail, 0, 8);
         #endif

         // extract the maximum response
         minMaxLoc( response, &minVal, &maxVal, &minLoc, &maxLoc );
         roi.x+=(maxLoc.x-roi.width/2+1);
         roi.y+=(maxLoc.y-roi.height/2+1);

         #if TIME == 2
         updateTimeDetail(&startDetectionDetail, 0, 9);
         #endif
       }

       #if TIME
       updateTime(startDetection, 0);

       double startPatches = CycleTimer::currentSeconds();
       #endif

       #if TIME == 2
       double startPatchesDetail = startPatches;
       #endif

       // update the bounding box
       boundingBox.x=(resizeImage?roi.x*2:roi.x)+(resizeImage?roi.width*2:roi.width)/4;
       boundingBox.y=(resizeImage?roi.y*2:roi.y)+(resizeImage?roi.height*2:roi.height)/4;
       boundingBox.width = (resizeImage?roi.width*2:roi.width)/2;
       boundingBox.height = (resizeImage?roi.height*2:roi.height)/2;

       #if TIME == 2
       updateTimeDetail(&startPatchesDetail, 1, 0);
       #endif

       // extract the patch for learning purpose
       // get non compressed descriptors
       for(unsigned i=0;i<descriptors_npca.size()-extractor_npca.size();i++){
         if(!getSubWindow(img,roi, features_npca[i], img_Patch, descriptors_npca[i]))return false;
       }

       #if TIME == 2
       updateTimeDetail(&startPatchesDetail, 1, 1);
       #endif


       //get non-compressed custom descriptors
       for(unsigned i=0,j=(unsigned)(descriptors_npca.size()-extractor_npca.size());i<extractor_npca.size();i++,j++){
         if(!getSubWindow(img,roi, features_npca[j], extractor_npca[i]))return false;
       }
       if(features_npca.size()>0)merge(features_npca,X[1]);

       #if TIME == 2
       updateTimeDetail(&startPatchesDetail, 1, 2);
       #endif

       // get compressed descriptors
       for(unsigned i=0;i<descriptors_pca.size()-extractor_pca.size();i++){
         if(!getSubWindow(img,roi, features_pca[i], img_Patch, descriptors_pca[i]))return false;
       }

       #if TIME == 2
       updateTimeDetail(&startPatchesDetail, 1, 3);
       #endif

       //get compressed custom descriptors
       for(unsigned i=0,j=(unsigned)(descriptors_pca.size()-extractor_pca.size());i<extractor_pca.size();i++,j++){
         if(!getSubWindow(img,roi, features_pca[j], extractor_pca[i]))return false;
       }
       if(features_pca.size()>0)merge(features_pca,X[0]);

       #if TIME == 2
       updateTimeDetail(&startPatchesDetail, 1, 4);
       #endif

       //update the training data
       if(frame==0){
         Z[0] = X[0].clone();
         Z[1] = X[1].clone();
       }else{
         Z[0]=(1.0-params.interp_factor)*Z[0]+params.interp_factor*X[0];
         Z[1]=(1.0-params.interp_factor)*Z[1]+params.interp_factor*X[1];
       }

       #if TIME == 2
       updateTimeDetail(&startPatchesDetail, 1, 5);
       #endif

       #if TIME
       updateTime(startPatches, 1);
       double startCompression = CycleTimer::currentSeconds();
       #endif

       #if TIME == 2
       double startCompressionDetail = startCompression;
       #endif


       if(params.desc_pca !=0 || use_custom_extractor_pca){
         // initialize the vector of Mat variables
         if(frame==0){
           layers_pca_data.resize(Z[0].channels());
           average_data.resize(Z[0].channels());
         }

         // feature compression
         updateProjectionMatrix(Z[0],old_cov_mtx,proj_mtx,params.pca_learning_rate,params.compressed_size,layers_pca_data,average_data,data_pca, new_covar,w_data,u_data,vt_data);

         #if TIME == 2
         updateTimeDetail(&startCompressionDetail, 2, 0);
         #endif

         compress(proj_mtx,X[0],X[0],data_temp,compress_data);

         #if TIME == 2
         updateTimeDetail(&startCompressionDetail, 2, 1);
         #endif
       }

       // merge all features
       if(features_npca.size()==0)
         x = X[0];
       else if(features_pca.size()==0)
         x = X[1];
       else
         merge(X,2,x);

       #if TIME == 2
       updateTimeDetail(&startCompressionDetail, 2, 2);
       #endif

       #if TIME
       updateTime(startCompression, 2);
       double startLeastSquares = CycleTimer::currentSeconds();
       #endif


       #if TIME == 2
       double startLeastSquaresDetail = startLeastSquares;
       #endif

       // initialize some required Mat variables
       if(frame==0){
         layers.resize(x.channels());
         vxf.resize(x.channels());
         vyf.resize(x.channels());
         vxyf.resize(vyf.size());
         new_alphaf=Mat_<Vec2d >(yf.rows, yf.cols);
       }

       #if TIME == 2
       updateTimeDetail(&startLeastSquaresDetail, 3, 0);
       #endif

       // Kernel Regularized Least-Squares, calculate alphas
       denseGaussKernel(params.sigma,x,x,k,layers,vxf,vyf,vxyf,xy_data,xyf_data);

       #if TIME == 2
       updateTimeDetail(&startLeastSquaresDetail, 3, 1);
       #endif

       // compute the fourier transform of the kernel and add a small value
       fft2(k,kf);

       #if TIME == 2
       updateTimeDetail(&startLeastSquaresDetail, 3, 2);
       #endif

       kf_lambda=kf+params.lambda;

       #if TIME == 2
       updateTimeDetail(&startLeastSquaresDetail, 3, 3);
       #endif

       double den;
       if(params.split_coeff){
         mulSpectrums(yf,kf,new_alphaf,0);
         mulSpectrums(kf,kf_lambda,new_alphaf_den,0);
       }else{
         for(int i=0;i<yf.rows;i++){
           for(int j=0;j<yf.cols;j++){
             den = 1.0/(kf_lambda.at<Vec2d>(i,j)[0]*kf_lambda.at<Vec2d>(i,j)[0]+kf_lambda.at<Vec2d>(i,j)[1]*kf_lambda.at<Vec2d>(i,j)[1]);

             new_alphaf.at<Vec2d>(i,j)[0]=
             (yf.at<Vec2d>(i,j)[0]*kf_lambda.at<Vec2d>(i,j)[0]+yf.at<Vec2d>(i,j)[1]*kf_lambda.at<Vec2d>(i,j)[1])*den;
             new_alphaf.at<Vec2d>(i,j)[1]=
             (yf.at<Vec2d>(i,j)[1]*kf_lambda.at<Vec2d>(i,j)[0]-yf.at<Vec2d>(i,j)[0]*kf_lambda.at<Vec2d>(i,j)[1])*den;
           }
         }
       }

       #if TIME == 2
       updateTimeDetail(&startLeastSquaresDetail, 3, 4);
       #endif

       // update the RLS model
       if(frame==0){
         alphaf=new_alphaf.clone();
         if(params.split_coeff)alphaf_den=new_alphaf_den.clone();
       }else{
         alphaf=(1.0-params.interp_factor)*alphaf+params.interp_factor*new_alphaf;
         if(params.split_coeff)alphaf_den=(1.0-params.interp_factor)*alphaf_den+params.interp_factor*new_alphaf_den;
       }

       #if TIME == 2
       updateTimeDetail(&startLeastSquaresDetail, 3, 5);
       #endif

       frame++;
       #if TIME
       updateTime(startLeastSquares, 3);
       updateTime(startUpdate, 4);
       printAverageTimes();
       #endif

       return true;
     }


     /*-------------------------------------
     |  implementation of the KCF functions
     |-------------------------------------*/

     /*
      * hann window filter
      */
     void TackerKCFImplParallel::createHanningWindow(OutputArray dest, const cv::Size winSize, const int type) const {
         CV_Assert( type == CV_32FC1 || type == CV_64FC1 );

         dest.create(winSize, type);
         Mat dst = dest.getMat();

         int rows = dst.rows, cols = dst.cols;

         AutoBuffer<double> _wc(cols);
         double * const wc = (double *)_wc;

         double coeff0 = 2.0 * CV_PI / (double)(cols - 1), coeff1 = 2.0f * CV_PI / (double)(rows - 1);
         for(int j = 0; j < cols; j++)
           wc[j] = 0.5 * (1.0 - cos(coeff0 * j));

         if(dst.depth() == CV_32F){
           for(int i = 0; i < rows; i++){
             float* dstData = dst.ptr<float>(i);
             double wr = 0.5 * (1.0 - cos(coeff1 * i));
             for(int j = 0; j < cols; j++)
               dstData[j] = (float)(wr * wc[j]);
           }
         }else{
           for(int i = 0; i < rows; i++){
             double* dstData = dst.ptr<double>(i);
             double wr = 0.5 * (1.0 - cos(coeff1 * i));
             for(int j = 0; j < cols; j++)
               dstData[j] = wr * wc[j];
           }
         }

         // perform batch sqrt for SSE performance gains
         //cv::sqrt(dst, dst); //matlab do not use the square rooted version
     }

     /*
      * simplification of fourier transform function in opencv
      */
     void inline TackerKCFImplParallel::fft2(const Mat src, Mat & dest) const {
       dft(src,dest,DFT_COMPLEX_OUTPUT);
     }

     void inline TackerKCFImplParallel::fft2(const Mat src, std::vector<Mat> & dest, std::vector<Mat> & layers_data) const {
       split(src, layers_data);

       for(int i=0;i<src.channels();i++){
         dft(layers_data[i],dest[i],DFT_COMPLEX_OUTPUT);
       }
     }

     /*
      * simplification of inverse fourier transform function in opencv
      */
     void inline TackerKCFImplParallel::ifft2(const Mat src, Mat & dest) const {
       cuda::dft(src,dest,src.size(),DFT_SCALE+DFT_REAL_OUTPUT|DFT_INVERSE);
     }

     /*
      * Point-wise multiplication of two Multichannel Mat data
      */
     void inline TackerKCFImplParallel::pixelWiseMult(const std::vector<Mat> src1, const std::vector<Mat>  src2, std::vector<Mat>  & dest, const int flags, const bool conjB) const {
       for(unsigned i=0;i<src1.size();i++){
         mulSpectrums(src1[i], src2[i], dest[i],flags,conjB);
       }
     }

     /*
      * Combines all channels in a multi-channels Mat data into a single channel
      */
     void inline TackerKCFImplParallel::sumChannels(std::vector<Mat> src, Mat & dest) const {
       dest=src[0].clone();
       for(unsigned i=1;i<src.size();i++){
         dest+=src[i];
       }
     }

     /*
      * obtains the projection matrix using PCA
      */
     void inline TackerKCFImplParallel::updateProjectionMatrix(const Mat src, Mat & old_cov,Mat &  proj_matrix, double pca_rate, int compressed_sz,
                                                        std::vector<Mat> & layers_pca,std::vector<Scalar> & average, Mat pca_data, Mat new_cov, Mat w, Mat u, Mat vt) const {
       CV_Assert(compressed_sz<=src.channels());

       split(src,layers_pca);

       for (int i=0;i<src.channels();i++){
         average[i]=mean(layers_pca[i]);
         layers_pca[i]-=average[i];
       }

       // calc covariance matrix
       merge(layers_pca,pca_data);
       pca_data=pca_data.reshape(1,src.rows*src.cols);

       new_cov=1.0/(double)(src.rows*src.cols-1)*(pca_data.t()*pca_data);
       if(old_cov.rows==0)old_cov=new_cov.clone();

       // calc PCA
       SVD::compute((1.0-pca_rate)*old_cov+pca_rate*new_cov, w, u, vt);

       // extract the projection matrix
       proj_matrix=u(Rect(0,0,compressed_sz,src.channels())).clone();
       Mat proj_vars=Mat::eye(compressed_sz,compressed_sz,proj_matrix.type());
       for(int i=0;i<compressed_sz;i++){
         proj_vars.at<double>(i,i)=w.at<double>(i);
       }

       // update the covariance matrix
       old_cov=(1.0-pca_rate)*old_cov+pca_rate*proj_matrix*proj_vars*proj_matrix.t();
     }

     /*
      * compress the features
      */
     void inline TackerKCFImplParallel::compress(const Mat proj_matrix, const Mat src, Mat & dest, Mat & data, Mat & compressed) const {
       data=src.reshape(1,src.rows*src.cols);
       compressed=data*proj_matrix;
       dest=compressed.reshape(proj_matrix.cols,src.rows).clone();
     }

     /*
      * obtain the patch and apply hann window filter to it
      */
     bool TackerKCFImplParallel::getSubWindow(const Mat img, const Rect _roi, Mat& feat, Mat& patch, TrackerKCF::MODE desc) const {

       Rect region=_roi;

       // return false if roi is outside the image
       if((_roi.x+_roi.width<0)
         ||(_roi.y+_roi.height<0)
         ||(_roi.x>=img.cols)
         ||(_roi.y>=img.rows)
       )return false;

       // extract patch inside the image
       if(_roi.x<0){region.x=0;region.width+=_roi.x;}
       if(_roi.y<0){region.y=0;region.height+=_roi.y;}
       if(_roi.x+_roi.width>img.cols)region.width=img.cols-_roi.x;
       if(_roi.y+_roi.height>img.rows)region.height=img.rows-_roi.y;
       if(region.width>img.cols)region.width=img.cols;
       if(region.height>img.rows)region.height=img.rows;

       patch=img(region).clone();

       // add some padding to compensate when the patch is outside image border
       int addTop,addBottom, addLeft, addRight;
       addTop=region.y-_roi.y;
       addBottom=(_roi.height+_roi.y>img.rows?_roi.height+_roi.y-img.rows:0);
       addLeft=region.x-_roi.x;
       addRight=(_roi.width+_roi.x>img.cols?_roi.width+_roi.x-img.cols:0);

       copyMakeBorder(patch,patch,addTop,addBottom,addLeft,addRight,BORDER_REPLICATE);
       if(patch.rows==0 || patch.cols==0)return false;

       // extract the desired descriptors
       switch(desc){
         case CN:
           CV_Assert(img.channels() == 3);
           extractCN(patch,feat);
           feat=feat.mul(hann_cn); // hann window filter
           break;
         default: // GRAY
           if(img.channels()>1)
             cvtColor(patch,feat, CV_BGR2GRAY);
           else
             feat=patch;
           feat.convertTo(feat,CV_64F);
           feat=feat/255.0-0.5; // normalize to range -0.5 .. 0.5
           feat=feat.mul(hann); // hann window filter
           break;
       }

       return true;

     }

     /*
      * get feature using external function
      */
     bool TackerKCFImplParallel::getSubWindow(const Mat img, const Rect _roi, Mat& feat, void (*f)(const Mat, const Rect, Mat& )) const{

       // return false if roi is outside the image
       if((_roi.x+_roi.width<0)
         ||(_roi.y+_roi.height<0)
         ||(_roi.x>=img.cols)
         ||(_roi.y>=img.rows)
       )return false;

       f(img, _roi, feat);

       if(_roi.width != feat.cols || _roi.height != feat.rows){
         printf("error in customized function of features extractor!\n");
         printf("Rules: roi.width==feat.cols && roi.height = feat.rows \n");
       }

       Mat hann_win;
       std::vector<Mat> _layers;

       for(int i=0;i<feat.channels();i++)
         _layers.push_back(hann);

       merge(_layers, hann_win);

       feat=feat.mul(hann_win); // hann window filter

       return true;
     }

     /* Convert BGR to ColorNames
      */
     void TackerKCFImplParallel::extractCN(Mat patch_data, Mat & cnFeatures) const {
       Vec3b & pixel = patch_data.at<Vec3b>(0,0);
       unsigned index;

       if(cnFeatures.type() != CV_64FC(10))
         cnFeatures = Mat::zeros(patch_data.rows,patch_data.cols,CV_64FC(10));

       for(int i=0;i<patch_data.rows;i++){
         for(int j=0;j<patch_data.cols;j++){
           pixel=patch_data.at<Vec3b>(i,j);
           index=(unsigned)(floor((float)pixel[2]/8)+32*floor((float)pixel[1]/8)+32*32*floor((float)pixel[0]/8));

           //copy the values
           for(int _k=0;_k<10;_k++){
             cnFeatures.at<Vec<double,10> >(i,j)[_k]=ColorNames[index][_k];
           }
         }
       }

     }

     /*
      *  dense gauss kernel function
      */
     void TackerKCFImplParallel::denseGaussKernel(const double sigma, const Mat x_data, const Mat y_data, Mat & k_data,
                                           std::vector<Mat> & layers_data,std::vector<Mat> & xf_data,std::vector<Mat> & yf_data, std::vector<Mat> xyf_v, Mat xy, Mat xyf ) const {
       double normX, normY;

       fft2(x_data,xf_data,layers_data);
       fft2(y_data,yf_data,layers_data);

       normX=norm(x_data);
       normX*=normX;
       normY=norm(y_data);
       normY*=normY;

       pixelWiseMult(xf_data,yf_data,xyf_v,0,true);
       sumChannels(xyf_v,xyf);
       ifft2(xyf,xyf);

       if(params.wrap_kernel){
         shiftRows(xyf, x_data.rows/2);
         shiftCols(xyf, x_data.cols/2);
       }

       //(xx + yy - 2 * xy) / numel(x)
       xy=(normX+normY-2*xyf)/(x_data.rows*x_data.cols*x_data.channels());

       // TODO: check wether we really need thresholding or not
       //threshold(xy,xy,0.0,0.0,THRESH_TOZERO);//max(0, (xx + yy - 2 * xy) / numel(x))
       for(int i=0;i<xy.rows;i++){
         for(int j=0;j<xy.cols;j++){
           if(xy.at<double>(i,j)<0.0)xy.at<double>(i,j)=0.0;
         }
       }

       double sig=-1.0/(sigma*sigma);
       xy=sig*xy;
       exp(xy,k_data);

     }

     /* CIRCULAR SHIFT Function
      * http://stackoverflow.com/questions/10420454/shift-like-matlab-function-rows-or-columns-of-a-matrix-in-opencv
      */
     // circular shift one row from up to down
     void TackerKCFImplParallel::shiftRows(Mat& mat) const {

         Mat temp;
         Mat m;
         int _k = (mat.rows-1);
         mat.row(_k).copyTo(temp);
         for(; _k > 0 ; _k-- ) {
           m = mat.row(_k);
           mat.row(_k-1).copyTo(m);
         }
         m = mat.row(0);
         temp.copyTo(m);

     }

     // circular shift n rows from up to down if n > 0, -n rows from down to up if n < 0
     void TackerKCFImplParallel::shiftRows(Mat& mat, int n) const {
         if( n < 0 ) {
           n = -n;
           flip(mat,mat,0);
           for(int _k=0; _k < n;_k++) {
             shiftRows(mat);
           }
           flip(mat,mat,0);
         }else{
           for(int _k=0; _k < n;_k++) {
             shiftRows(mat);
           }
         }
     }

     //circular shift n columns from left to right if n > 0, -n columns from right to left if n < 0
     void TackerKCFImplParallel::shiftCols(Mat& mat, int n) const {
         if(n < 0){
           n = -n;
           flip(mat,mat,1);
           transpose(mat,mat);
           shiftRows(mat,n);
           transpose(mat,mat);
           flip(mat,mat,1);
         }else{
           transpose(mat,mat);
           shiftRows(mat,n);
           transpose(mat,mat);
         }
     }

     /*
      * calculate the detection response
      */
     void TackerKCFImplParallel::calcResponse(const Mat alphaf_data, const Mat kf_data, Mat & response_data, Mat & spec_data) const {
       //alpha f--> 2channels ; k --> 1 channel;
       mulSpectrums(alphaf_data,kf_data,spec_data,0,false);
       ifft2(spec_data,response_data);
     }

     /*
      * calculate the detection response for splitted form
      */
     void TackerKCFImplParallel::calcResponse(const Mat alphaf_data, const Mat _alphaf_den, const Mat kf_data, Mat & response_data, Mat & spec_data, Mat & spec2_data) const {

       mulSpectrums(alphaf_data,kf_data,spec_data,0,false);

       //z=(a+bi)/(c+di)=[(ac+bd)+i(bc-ad)]/(c^2+d^2)
       double den;
       for(int i=0;i<kf_data.rows;i++){
         for(int j=0;j<kf_data.cols;j++){
           den=1.0/(_alphaf_den.at<Vec2d>(i,j)[0]*_alphaf_den.at<Vec2d>(i,j)[0]+_alphaf_den.at<Vec2d>(i,j)[1]*_alphaf_den.at<Vec2d>(i,j)[1]);
           spec2_data.at<Vec2d>(i,j)[0]=
             (spec_data.at<Vec2d>(i,j)[0]*_alphaf_den.at<Vec2d>(i,j)[0]+spec_data.at<Vec2d>(i,j)[1]*_alphaf_den.at<Vec2d>(i,j)[1])*den;
           spec2_data.at<Vec2d>(i,j)[1]=
             (spec_data.at<Vec2d>(i,j)[1]*_alphaf_den.at<Vec2d>(i,j)[0]-spec_data.at<Vec2d>(i,j)[0]*_alphaf_den.at<Vec2d>(i,j)[1])*den;
         }
       }

       ifft2(spec2_data,response_data);
     }

     void TackerKCFImplParallel::setFeatureExtractor(void (*f)(const Mat, const Rect, Mat&), bool pca_func){
       if(pca_func){
         extractor_pca.push_back(f);
         use_custom_extractor_pca = true;
       }else{
         extractor_npca.push_back(f);
         use_custom_extractor_npca = true;
       }
     }
     /*----------------------------------------------------------------------*/
}
