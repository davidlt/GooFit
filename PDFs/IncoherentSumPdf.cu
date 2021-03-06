#include "IncoherentSumPdf.hh"
#include "devcomplex.hh" 
#include "ResonancePdf.hh"

const int resonanceOffset_incoherent = 4; // Offset of the first resonance into the parameter index array. 
// Notice that this is different from the TddpPdf case because there's no time information. 
// In particular the offset consists of nP, constant index, number of resonances, and cache index. 

MEM_DEVICE devcomplex<fptype>* cResonanceValues[10]; 

EXEC_TARGET inline int parIndexFromResIndex_incoherent (int resIndex) {
  return resonanceOffset_incoherent + resIndex*resonanceSize; 
}

EXEC_TARGET fptype device_incoherent (fptype* evt, fptype* p, unsigned int* indices) {
  // Calculates the incoherent sum over the resonances. 
  int evtNum = (int) FLOOR(0.5 + evt[indices[4 + indices[0]]]); 

  fptype ret = 0; 
  unsigned int numResonances = indices[2]; 
  unsigned int cacheToUse    = indices[3]; 
  for (int i = 0; i < numResonances; ++i) {
    int paramIndex  = parIndexFromResIndex_incoherent(i);
    fptype amplitude = p[indices[paramIndex+0]];

    devcomplex<fptype> matrixelement = cResonanceValues[cacheToUse][evtNum*numResonances + i];
    ret += amplitude * matrixelement.abs2();
  } 

  // Multiply by efficiency  
  int effFunctionIdx = parIndexFromResIndex_incoherent(numResonances); 
  fptype eff = callFunction(evt, indices[effFunctionIdx], indices[effFunctionIdx + 1]); 

  ret *= eff;

  return ret; 
}

MEM_DEVICE device_function_ptr ptr_to_incoherent = device_incoherent; 

__host__ IncoherentSumPdf::IncoherentSumPdf (std::string n, Variable* m12, Variable* m13, Variable* eventNumber, DecayInfo* decay, GooPdf* eff) 
  : GooPdf(0, n) 
  , decayInfo(decay)
  , _m12(m12)
  , _m13(m13)
  , dalitzNormRange(0)
  , cachedResonances(0) 
  , integrals(0)
  , forceRedoIntegrals(true)
  , totalEventSize(3) // Default 3 = m12, m13, evtNum. Will likely be overridden.
  , cacheToUse(0)
  , efficiency(eff)
  , integrators(0)
  , calculators(0) 
{
  registerObservable(_m12);
  registerObservable(_m13);
  registerObservable(eventNumber); 

  std::vector<unsigned int> pindices;
  pindices.push_back(registerConstants(5)); 
  fptype decayConstants[5];
  decayConstants[0] = decayInfo->motherMass;
  decayConstants[1] = decayInfo->daug1Mass;
  decayConstants[2] = decayInfo->daug2Mass;
  decayConstants[3] = decayInfo->daug3Mass;
  decayConstants[4] = decayInfo->meson_radius;
  MEMCPY_TO_SYMBOL(functorConstants, decayConstants, 5*sizeof(fptype), cIndex*sizeof(fptype), cudaMemcpyHostToDevice);  

  pindices.push_back(decayInfo->resonances.size()); 
  static int cacheCount = 0; 
  cacheToUse = cacheCount++; 
  pindices.push_back(cacheToUse); 

  for (std::vector<ResonancePdf*>::iterator res = decayInfo->resonances.begin(); res != decayInfo->resonances.end(); ++res) {
    pindices.push_back(registerParameter((*res)->amp_real));
    pindices.push_back(registerParameter((*res)->amp_real)); 
    // Not going to use amp_imag, but need a dummy index so the resonance size will be consistent.
    pindices.push_back((*res)->getFunctionIndex());
    pindices.push_back((*res)->getParameterIndex());
    (*res)->setConstantIndex(cIndex); 
    components.push_back(*res);
  }

  pindices.push_back(efficiency->getFunctionIndex());
  pindices.push_back(efficiency->getParameterIndex());
  components.push_back(efficiency); 

  GET_FUNCTION_ADDR(ptr_to_incoherent);
  initialise(pindices); 

  redoIntegral = new bool[decayInfo->resonances.size()];
  cachedMasses = new fptype[decayInfo->resonances.size()];
  cachedWidths = new fptype[decayInfo->resonances.size()];
  integrals = new double[decayInfo->resonances.size()];

  for (int i = 0; i < decayInfo->resonances.size(); ++i) {
    redoIntegral[i] = true;
    cachedMasses[i] = -1;
    cachedWidths[i] = -1; 
    integrals[i] = 0; 
  }

  integrators = new SpecialIncoherentIntegrator*[decayInfo->resonances.size()];
  calculators = new SpecialIncoherentResonanceCalculator*[decayInfo->resonances.size()];
  for (int i = 0; i < decayInfo->resonances.size(); ++i) {
    integrators[i] = new SpecialIncoherentIntegrator(parameters, i); 
    calculators[i] = new SpecialIncoherentResonanceCalculator(parameters, i); 
  }


  addSpecialMask(PdfBase::ForceSeparateNorm); 
}

__host__ void IncoherentSumPdf::setDataSize (unsigned int dataSize, unsigned int evtSize) {
  // Default 3 is m12, m13, evtNum
  totalEventSize = evtSize;
  assert(totalEventSize >= 3); 

  if (cachedResonances) {
    delete cachedResonances;
  }

  numEntries = dataSize; 
  cachedResonances = new DEVICE_VECTOR<devcomplex<fptype> >(dataSize*decayInfo->resonances.size());
  void* dummy = thrust::raw_pointer_cast(cachedResonances->data()); 
  MEMCPY_TO_SYMBOL(cResonanceValues, &dummy, sizeof(devcomplex<fptype>*), cacheToUse*sizeof(devcomplex<fptype>*), cudaMemcpyHostToDevice); 
  setForceIntegrals(); 
}

__host__ fptype IncoherentSumPdf::normalise () const {
  recursiveSetNormalisation(1); // Not going to normalise efficiency, 
  // so set normalisation factor to 1 so it doesn't get multiplied by zero. 
  // Copy at this time to ensure that the SpecialCalculators, which need the efficiency, 
  // don't get zeroes through multiplying by the normFactor. 
  MEMCPY_TO_SYMBOL(normalisationFactors, host_normalisation, totalParams*sizeof(fptype), 0, cudaMemcpyHostToDevice); 

  int totalBins = _m12->numbins * _m13->numbins;
  if (!dalitzNormRange) {
    gooMalloc((void**) &dalitzNormRange, 6*sizeof(fptype));
  
    fptype* host_norms = new fptype[6];
    host_norms[0] = _m12->lowerlimit;
    host_norms[1] = _m12->upperlimit;
    host_norms[2] = _m12->numbins;
    host_norms[3] = _m13->lowerlimit;
    host_norms[4] = _m13->upperlimit;
    host_norms[5] = _m13->numbins;
    MEMCPY(dalitzNormRange, host_norms, 6*sizeof(fptype), cudaMemcpyHostToDevice);
    delete[] host_norms; 
  }

  // Check if efficiency changes force redoing the integrals.
  if (efficiency->parametersChanged()) {
    forceRedoIntegrals = true; 
    efficiency->storeParameters();
  } 

  // Check for changed masses or forced integral redo. 
  for (unsigned int i = 0; i < decayInfo->resonances.size(); ++i) {
    redoIntegral[i] = forceRedoIntegrals; 
    if (!(decayInfo->resonances[i]->parametersChanged())) continue;
    redoIntegral[i] = true; 
    decayInfo->resonances[i]->storeParameters();
  }
  forceRedoIntegrals = false; 

  thrust::constant_iterator<fptype*> arrayAddress(dalitzNormRange); 
  thrust::counting_iterator<int> binIndex(0); 

  // NB, SpecialIncoherentResonanceCalculator assumes that fit is unbinned! 
  // And it needs to know the total event size, not just observables
  // for this particular PDF component. 
  thrust::constant_iterator<fptype*> dataArray(dev_event_array); 
  thrust::constant_iterator<int> eventSize(totalEventSize);
  thrust::counting_iterator<int> eventIndex(0); 

  for (int i = 0; i < decayInfo->resonances.size(); ++i) {
    if (redoIntegral[i]) {      
      thrust::transform(thrust::make_zip_iterator(thrust::make_tuple(eventIndex, dataArray, eventSize)),
			thrust::make_zip_iterator(thrust::make_tuple(eventIndex + numEntries, arrayAddress, eventSize)),
			strided_range<DEVICE_VECTOR<devcomplex<fptype> >::iterator>(cachedResonances->begin() + i, 
										    cachedResonances->end(), 
										    decayInfo->resonances.size()).begin(), 
			*(calculators[i]));

      fptype dummy = 0;
      static thrust::plus<fptype> cudaPlus;
      integrals[i] = thrust::transform_reduce(thrust::make_zip_iterator(thrust::make_tuple(binIndex, arrayAddress)),
					      thrust::make_zip_iterator(thrust::make_tuple(binIndex + totalBins, arrayAddress)),
					      *(integrators[i]), 
					      dummy, 
					      cudaPlus); 
    } 
  }      

  // End of time-consuming integrals and caching of BWs over Dalitz plot.

  fptype ret = 0; 
  for (unsigned int i = 0; i < decayInfo->resonances.size(); ++i) {
    int param_i = parameters + resonanceOffset_incoherent + resonanceSize * i; 
    fptype amplitude = host_params[host_indices[param_i]];
    ret += amplitude * integrals[i]; 
  }

  double binSizeFactor = 1;
  binSizeFactor *= ((_m12->upperlimit - _m12->lowerlimit) / _m12->numbins);
  binSizeFactor *= ((_m13->upperlimit - _m13->lowerlimit) / _m13->numbins);
  ret *= binSizeFactor;

  host_normalisation[parameters] = 1.0/ret;
  return (fptype) ret; 
}

SpecialIncoherentIntegrator::SpecialIncoherentIntegrator (int pIdx, unsigned int ri) 
  : resonance_i(ri)
  , parameters(pIdx) 
{}

EXEC_TARGET fptype SpecialIncoherentIntegrator::operator () (thrust::tuple<int, fptype*> t) const {
  // Returns integral of specific BW over Dalitz plot, to be cached and
  // multiplied by rapidly-changing amplitude. 

  // Bin index, base address [lower, upper, numbins] 
  // Notice that this is basically MetricTaker::operator (binned) with the special-case knowledge
  // that event size is two, and that the function to call is getResonanceAmplitude. 

  int globalBinNumber  = thrust::get<0>(t);
  fptype lowerBoundM12 = thrust::get<1>(t)[0];
  fptype upperBoundM12 = thrust::get<1>(t)[1];  
  int numBinsM12       = (int) FLOOR(thrust::get<1>(t)[2] + 0.5); 
  int binNumberM12     = globalBinNumber % numBinsM12;
  fptype binCenterM12  = upperBoundM12 - lowerBoundM12;
  binCenterM12        /= numBinsM12;
  binCenterM12        *= (binNumberM12 + 0.5); 
  binCenterM12        += lowerBoundM12; 

  globalBinNumber     /= numBinsM12; 
  fptype lowerBoundM13 = thrust::get<1>(t)[3];
  fptype upperBoundM13 = thrust::get<1>(t)[4];  
  int numBinsM13       = (int) FLOOR(thrust::get<1>(t)[5] + 0.5); 
  fptype binCenterM13  = upperBoundM13 - lowerBoundM13;
  binCenterM13        /= numBinsM13;
  binCenterM13        *= (globalBinNumber + 0.5); 
  binCenterM13        += lowerBoundM13; 

  unsigned int* indices = paramIndices + parameters;   
  fptype motherMass = functorConstants[indices[1] + 0]; 
  fptype daug1Mass  = functorConstants[indices[1] + 1]; 
  fptype daug2Mass  = functorConstants[indices[1] + 2]; 
  fptype daug3Mass  = functorConstants[indices[1] + 3];  

  if (!inDalitz(binCenterM12, binCenterM13, motherMass, daug1Mass, daug2Mass, daug3Mass)) return 0;

  int parameter_i = parIndexFromResIndex_incoherent(resonance_i); // Find position of this resonance relative to TDDP start 
  unsigned int functn_i = indices[parameter_i+2];
  unsigned int params_i = indices[parameter_i+3];
  fptype m23 = motherMass*motherMass + daug1Mass*daug1Mass + daug2Mass*daug2Mass + daug3Mass*daug3Mass - binCenterM12 - binCenterM13; 
  devcomplex<fptype> ret = getResonanceAmplitude(binCenterM12, binCenterM13, m23, functn_i, params_i);

  unsigned int numResonances = indices[2]; 
  fptype fakeEvt[10]; // Need room for many observables in case m12 or m13 were assigned a high index in an event-weighted fit. 
  fakeEvt[indices[indices[0] + 2 + 0]] = binCenterM12;
  fakeEvt[indices[indices[0] + 2 + 1]] = binCenterM13;
  int effFunctionIdx = parIndexFromResIndex_incoherent(numResonances); 
  fptype eff = callFunction(fakeEvt, indices[effFunctionIdx], indices[effFunctionIdx + 1]); 

  return ret.abs2() * eff; 
}

SpecialIncoherentResonanceCalculator::SpecialIncoherentResonanceCalculator (int pIdx, unsigned int res_idx) 
  : resonance_i(res_idx)
  , parameters(pIdx)
{}

EXEC_TARGET devcomplex<fptype> SpecialIncoherentResonanceCalculator::operator () (thrust::tuple<int, fptype*, int> t) const {
  // Returns the BW, or other resonance function, for a specific resonance.
  // Is special because the value is expected to change slowly, so it's
  // useful to cache the result. 
  int evtNum = thrust::get<0>(t); 
  fptype* evt = thrust::get<1>(t) + (evtNum * thrust::get<2>(t)); 

  unsigned int* indices = paramIndices + parameters;   // Jump to TDDP position within parameters array
  fptype m12 = evt[indices[2 + indices[0]]]; 
  fptype m13 = evt[indices[3 + indices[0]]];
  fptype motherMass = functorConstants[indices[1] + 0]; 
  fptype daug1Mass  = functorConstants[indices[1] + 1]; 
  fptype daug2Mass  = functorConstants[indices[1] + 2]; 
  fptype daug3Mass  = functorConstants[indices[1] + 3];  
  if (!inDalitz(m12, m13, motherMass, daug1Mass, daug2Mass, daug3Mass)) return devcomplex<fptype>(0, 0); 
  fptype m23 = motherMass*motherMass + daug1Mass*daug1Mass + daug2Mass*daug2Mass + daug3Mass*daug3Mass - m12 - m13; 

  int parameter_i = parIndexFromResIndex_incoherent(resonance_i); // Find position of this resonance relative to TDDP start 
  unsigned int functn_i = indices[parameter_i+2];
  unsigned int params_i = indices[parameter_i+3];
  devcomplex<fptype> ret = getResonanceAmplitude(m12, m13, m23, functn_i, params_i);

  return ret; 
}

