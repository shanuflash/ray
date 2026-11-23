#ifndef RAY_LINUX_AC_LINUX_SECRET_TEXT_H_
#define RAY_LINUX_AC_LINUX_SECRET_TEXT_H_

#include <cstddef>
#include <memory>
#include <string_view>

namespace ray::linux_password {

void WipeBytes(void* data, size_t size);

class SecretPage {
 public:
  explicit SecretPage(size_t bytes);
  SecretPage(const SecretPage&) = delete;
  SecretPage& operator=(const SecretPage&) = delete;
  ~SecretPage();

  bool ok() const { return data_ != nullptr; }
  unsigned char* data() const { return data_; }
  size_t size() const { return size_; }

 private:
  unsigned char* data_ = nullptr;
  size_t size_ = 0;
  size_t mapped_ = 0;
};

class SecretBytes {
 public:
  explicit SecretBytes(size_t capacity);
  SecretBytes(const SecretBytes&) = delete;
  SecretBytes& operator=(const SecretBytes&) = delete;

  bool ok() const { return page_.ok(); }
  std::string_view view() const;
  bool Append(std::string_view bytes);
  void Clear();

 private:
  SecretPage page_;
  size_t capacity_ = 0;
  size_t size_ = 0;
};

class SecretText {
 public:
  explicit SecretText(size_t capacity_units);
  SecretText(const SecretText&) = delete;
  SecretText& operator=(const SecretText&) = delete;

  bool ok() const { return page_.ok(); }
  size_t size() const { return size_; }
  size_t cursor() const { return cursor_; }
  bool all_selected() const { return all_selected_ && size_ > 0; }
  bool empty() const { return size_ == 0; }
  std::u16string_view view() const;
  size_t CodePoints() const;
  size_t CodePointsBeforeCursor() const;

  bool Insert(std::u16string_view units);
  void Backspace();
  void BackspaceToStart();
  void DeleteForward();
  void DeleteSurrounding(size_t before, size_t after);
  void MoveLeft();
  void MoveRight();
  void MoveHome();
  void MoveEnd();
  void SelectAll();
  void Clear();
  std::unique_ptr<SecretBytes> Utf8() const;

 private:
  char16_t* units() const;
  size_t Before(size_t at) const;
  size_t After(size_t at) const;
  void Erase(size_t from, size_t to);
  bool TakeSelection();

  SecretPage page_;
  size_t capacity_ = 0;
  size_t size_ = 0;
  size_t cursor_ = 0;
  bool all_selected_ = false;
};

}

#endif
