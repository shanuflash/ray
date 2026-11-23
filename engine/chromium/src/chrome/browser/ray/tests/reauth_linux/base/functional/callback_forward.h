#pragma once
#include <functional>
#include <memory>
#include <type_traits>
#include <utility>
namespace base {
template <typename Signature>
class OnceCallback;
template <typename R, typename... Args>
class OnceCallback<R(Args...)> {
 public:
  OnceCallback() = default;
  template <typename F, typename = std::enable_if_t<!std::is_same_v<std::decay_t<F>, OnceCallback> &&
                                                    std::is_invocable_r_v<R, std::decay_t<F>&, Args...>>>
  OnceCallback(F function) : call_(std::make_unique<Holder<std::decay_t<F>>>(std::move(function))) {}
  OnceCallback(OnceCallback&&) = default;
  OnceCallback& operator=(OnceCallback&&) = default;
  explicit operator bool() const { return !!call_; }
  bool is_null() const { return !call_; }
  void Reset() { call_.reset(); }
  R Run(Args... args) && {
    auto call = std::move(call_);
    return call->Call(std::forward<Args>(args)...);
  }

 private:
  struct Callable {
    virtual ~Callable() = default;
    virtual R Call(Args... args) = 0;
  };
  template <typename F>
  struct Holder : Callable {
    explicit Holder(F function) : function(std::move(function)) {}
    R Call(Args... args) override { return function(std::forward<Args>(args)...); }
    F function;
  };
  std::unique_ptr<Callable> call_;
};
template <typename Signature>
class RepeatingCallback;
template <typename R, typename... Args>
class RepeatingCallback<R(Args...)> {
 public:
  RepeatingCallback() = default;
  template <typename F, typename = std::enable_if_t<!std::is_same_v<std::decay_t<F>, RepeatingCallback> &&
                                                    std::is_invocable_r_v<R, std::decay_t<F>&, Args...>>>
  RepeatingCallback(F function) : call_(std::make_shared<std::function<R(Args...)>>(std::move(function))) {}
  explicit operator bool() const { return !!call_; }
  R Run(Args... args) const { return (*call_)(std::forward<Args>(args)...); }

 private:
  std::shared_ptr<std::function<R(Args...)>> call_;
};
}
