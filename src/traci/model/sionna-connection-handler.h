/* -*- Mode:C++; c-file-style:"gnu"; indent-tabs-mode:nil; -*- */
/*
 * Stub header for non-Sionna builds.
 * The real implementation is provided by the sionna module (requires the
 * NVIDIA Sionna ray-tracing integration).  This stub satisfies the #include
 * in traci-client.h, gps-tc.h, and txTracker.h without pulling in any
 * Sionna dependencies.
 */

#ifndef SIONNA_CONNECTION_HANDLER_H
#define SIONNA_CONNECTION_HANDLER_H

#include "ns3/vector.h"
#include <string>

namespace ns3 {

// No-op stub: called by TraciClient when m_sionna==true, which only happens
// if SetSionnaUp() was explicitly invoked.  Without the real Sionna module
// that flag stays false, so this body is never reached at run-time.
inline void
updateLocationInSionna (const std::string & /* nodeId */,
                        const Vector & /* position */,
                        double /* angle */,
                        const Vector & /* velocity */)
{}

} // namespace ns3

#endif // SIONNA_CONNECTION_HANDLER_H
