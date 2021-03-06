// @file vl_nnbnorm.cu
// @brief Batch normalization MEX wrapper
// @author Sebastien Ehrhardt

/*
   Copyright (C) 2015 Sebastien Ehrhardt.
   All rights reserved.

   This file is part of the VLFeat library and is made available under
   the terms of the BSD license (see the COPYING file).
*/

#include "bits/mexutils.h"
#include "bits/nnbnorm.hpp"
#include "bits/datamex.hpp"

#if ENABLE_GPU
#include "bits/datacu.hpp"
#endif

#include <assert.h>

/* option codes */
enum {
  opt_verbose = 0,
  opt_epsilon,
} ;

/* options */
vlmxOption  options [] = {
  {"Verbose",          0,   opt_verbose           },
  {"Epsilon",	       1,   opt_epsilon           },
  {0,                  0,   0                     }
} ;

/* ---------------------------------------------------------------- */
/*                                                          Context */
/* ---------------------------------------------------------------- */

vl::MexContext context ;

/*
   Resetting the context here resolves a crash when MATLAB quits and
   the ~Context function is implicitly called on unloading the MEX file.
 */
void atExit()
{
  context.clear() ;
}

/* ---------------------------------------------------------------- */
/*                                                       MEX driver */
/* ---------------------------------------------------------------- */

enum {
  IN_DATA = 0, IN_MULTIPLIERS, IN_BIASES, IN_DEROUTPUT, IN_END
} ;

enum {
  OUT_RESULT = 0, OUT_DERMULTIPLIERS, OUT_DERBIASES, OUT_END
} ;

void mexFunction(int nout, mxArray *out[],
                 int nin, mxArray const *in[])
{
  bool backMode = false ;
  float epsilon = 10E-4 ;

  // For the moment true need to be fixed
  bool computeDerData = true ;
  bool computeDerMultipliers = true ;
  bool computeDerBiases = true ;

  int verbosity = 0 ;
  int opt ;
  int next = IN_END ;
  mxArray const *optarg ;

  /* -------------------------------------------------------------- */
  /*                                            Check the arguments */
  /* -------------------------------------------------------------- */

  if (nin < 3) {
    mexErrMsgTxt("The arguments are less than three.") ;
  }
  if (nin > 3 && vlmxIsString(in[3],-1)) {
    next = 3 ;
    backMode = 0 ;
  } else {
    backMode = (nin >= 4) ;
  }

  while ((opt = vlmxNextOption (in, nin, options, &next, &optarg)) >= 0) {
    switch (opt) {
      case opt_verbose :
        ++ verbosity ;
        break ;
      case opt_epsilon :
        if (!vlmxIsPlainScalar(optarg)) {
          mexErrMsgTxt("EPSILON is not a plain scalar.") ;
        }
        epsilon = (float)mxGetPr(optarg)[0] ;
      default: break ;
    }
  }

  vl::MexTensor data(context) ;
  vl::MexTensor multipliers(context);
  vl::MexTensor biases(context);
  vl::MexTensor derOutput(context) ;

  data.init(in[IN_DATA]) ;
  multipliers.init(in[IN_MULTIPLIERS]) ;
  biases.init(in[IN_BIASES]) ;
  if (backMode) { derOutput.init(in[IN_DEROUTPUT]) ; }

  /* Check for GPU/data class consistency */
  if (! vl::areCompatible(data, multipliers)) {
    mexErrMsgTxt("DATA and MULTIPLIERS are not both CPU or GPU arrays.") ;
  }
  if (! vl::areCompatible(data, biases)) {
    mexErrMsgTxt("DATA and BIASES are not both CPU or GPU arrays.") ;
  }
  if (backMode && ! vl::areCompatible(data, derOutput)) {
    mexErrMsgTxt("DATA and DEROUTPUT are not both CPU or GPU arrays.") ;
  }
  if (backMode && (data.getGeometry() != derOutput.getGeometry())) {
    mexErrMsgTxt("DATA and DEROUTPUT do not have the same size.") ;
  }

  /* Get the filter geometry */
  vl::TensorGeometry multipliersGeom(multipliers) ;
  if (multipliersGeom.getHeight() != data.getDepth()) {
    mexErrMsgTxt("The MULTIPLIERS size does not match the DATA depth.") ;
  }
  vl::TensorGeometry biasesGeom(biases);
  if (biasesGeom.getHeight() != data.getDepth()) {
    mexErrMsgTxt("The BIASES size does not match the DATA depth.") ;
  }

  /* Create output buffers */
  vl::Device type = data.getMemoryType() ;
  vl::MexTensor output(context) ;
  vl::MexTensor derData(context) ;
  vl::MexTensor derMultipliers(context) ;
  vl::MexTensor derBiases(context) ;

  if (!backMode) {
    output.init(type, data.getGeometry()) ;
  } else {
    if (computeDerData) {
      derData.init(type, data.getGeometry()) ;
    }
    if (computeDerMultipliers) {
      derMultipliers.init(type, multipliers.getGeometry()) ;
    }
    if (computeDerBiases) {
      derBiases.init(type, biases.getGeometry()) ;
    }
  }

  if (verbosity > 0) {
    mexPrintf("vl_nnbnorm: mode %s; %s\n",  (data.getMemoryType()==vl::GPU)?"gpu":"cpu", backMode?"backward":"forward") ;
    vl::print("vl_nnbnorm: data: ", data) ;
    vl::print("vl_nnbnorm: multipliers: ", multipliers) ;
    vl::print("vl_nnbnorm: biases: ", biases) ;
    if (backMode) {
      vl::print("vl_nnbnorm: derOutput: ", derOutput) ;
      vl::print("vl_nnbnorm: derData: ", derData) ;
      vl::print("vl_nnbnorm: derMultipliers: ", derMultipliers) ;
      vl::print("vl_nnbnorm: derBiases: ", derBiases) ;
    } else {
      vl::print("vl_nnbnorm: output: ", output) ;
    }
  }

  /* -------------------------------------------------------------- */
  /*                                                    Do the work */
  /* -------------------------------------------------------------- */

  vl::Error error ;

  if (!backMode) {
    error = vl::nnbnorm_forward(context,
                                output,
                                data,
                                multipliers,
                                biases,
                                epsilon) ;
  } else {
    error = vl::nnbnorm_backward(context,
                                 derData,
                                 derMultipliers,
                                 derBiases,
                                 data,
                                 multipliers,
                                 biases,
                                 derOutput,
                                 epsilon);
  }

  /* -------------------------------------------------------------- */
  /*                                                         Finish */
  /* -------------------------------------------------------------- */

  if (error != vl::vlSuccess) {
    mexErrMsgTxt(context.getLastErrorMessage().c_str()) ;
  }
  if (backMode) {
    out[OUT_RESULT] = (computeDerData) ? derData.relinquish() : mxCreateDoubleMatrix(0,0,mxREAL) ;
    out[OUT_DERMULTIPLIERS] = (computeDerMultipliers)? derMultipliers.relinquish() : mxCreateDoubleMatrix(0,0,mxREAL) ;
    out[OUT_DERBIASES] = (computeDerBiases) ? derBiases.relinquish() : mxCreateDoubleMatrix(0,0,mxREAL) ;
  } else {
    out[OUT_RESULT] = output.relinquish() ;
  }
}
