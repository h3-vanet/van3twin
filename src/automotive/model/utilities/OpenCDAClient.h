/* -*- Mode:C++; c-file-style:"gnu"; indent-tabs-mode:nil; -*- */
/*
 * Stub header for non-CARLA builds.
 * When CARLA/OpenCDA is installed the carla module provides the real
 * implementation and this file is shadowed by that module's installed header.
 */

#ifndef OPENCDA_CLIENT_H
#define OPENCDA_CLIENT_H

#include "ns3/object.h"

namespace ns3 {

/**
 * \brief Stub class used when the CARLA/OpenCDA module is not present.
 *
 * Code that holds a Ptr<OpenCDAClient> will compile cleanly; any attempt to
 * call methods on a non-null pointer will resolve to the no-op bodies below.
 * In practice, without a real OpenCDA installation the pointer is always
 * null, so none of these bodies are ever reached at run-time.
 */
class OpenCDAClient : public Object
{
public:
  static TypeId GetTypeId ()
  {
    static TypeId tid = TypeId ("ns3::OpenCDAClient").SetParent<Object> ();
    return tid;
  }
};

} // namespace ns3

#endif // OPENCDA_CLIENT_H
