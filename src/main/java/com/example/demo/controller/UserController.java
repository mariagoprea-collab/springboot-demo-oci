package com.example.demo.controller;

import com.example.demo.model.User;
import com.example.demo.repository.UserRepository;
import org.springframework.web.bind.annotation.*;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/users")
public class UserController {

    private final UserRepository userRepository;

    public UserController(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    @GetMapping
    public List<User> getAllUsers() {
        return userRepository.findAll();
    }

    @PostMapping
    public User createUser(@RequestBody Map<String, String> body) {
        String name = body.get("name");
        String dateTimeStr = body.get("scheduledDateTime"); // așteptat ca "2025-10-30T14:30"
        LocalDateTime scheduledDateTime = LocalDateTime.parse(dateTimeStr);
        User user = new User(name, scheduledDateTime);
        return  userRepository.save(user);
    }

    @PutMapping("/{id}/approve")
    public User approveUser(@PathVariable Long id) {
        User user = userRepository.findById(id).orElseThrow();
        return userRepository.save(user);
    }

    @PutMapping("/{id}/reject")
    public User rejectUser(@PathVariable Long id) {
        User user = userRepository.findById(id).orElseThrow();
        return userRepository.save(user);
    }

}
