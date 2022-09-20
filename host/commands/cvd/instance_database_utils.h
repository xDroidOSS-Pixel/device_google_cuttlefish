/*
 * Copyright (C) 2022 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include <algorithm>
#include <string>

#include "common/libs/utils/result.h"
#include "host/commands/cvd/instance_database_types.h"

namespace cuttlefish {
namespace instance_db {

std::string GenInternalGroupName();
std::string LocalDeviceNameRule(const std::string& group_name,
                                const std::string& instance_name);

/**
 * Specialized version of cuttlefish::Flatten
 *
 *  a. The result is stored in instance_db::Set<T>
 *  b. As not all Container candidate supports iterator over
 *    the elements, collect is responsible for gathering all
 *    elements in each container.
 *
 */
template <typename Element, typename Container, typename Containers>
Set<Element> CollectAllElements(
    std::function<Set<Element>(const Container&)> collector,
    const Containers& inputs) {
  Set<Element> output;
  for (const auto& container : inputs) {
    auto subset = collector(container);
    output.insert(subset.cbegin(), subset.cend());
  }
  return output;
}

}  // namespace instance_db
}  // namespace cuttlefish